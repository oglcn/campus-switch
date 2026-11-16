// CampusSwitch — menu bar front end for campusd.
// Shows the current mode, lets you force a mode, and handles the
// Tailscale Mac app (quit in campus mode, reopen afterwards).

import SwiftUI
import AppKit

let runDir = "/Library/Application Support/CampusSwitch/run"
let stateFile = runDir + "/state.json"
let modeFile = runDir + "/mode"
let triggerFile = runDir + "/trigger"
let logFile = "/Library/Logs/CampusSwitch.log"
let configFile = "/Library/Application Support/CampusSwitch/config"
let tsCLI = "/opt/homebrew/bin/tailscale"
let tsSocket = "--socket=/var/run/tailscaled-cli.socket"
let tailscaleAppID = "io.tailscale.ipn.macsys"

struct DaemonState: Decodable, Equatable {
    var state: String
    var reason: String
    var mode: String
    var iface: String
    var gateway: String
    var service: String
    var since: Double
    var checked: Double
    var tailscaled: Bool
}

final class Model: ObservableObject {
    @Published var st: DaemonState?
    @Published var mode = "auto"
    @Published var peerResult = ""
    @Published var stale = false

    private var timer: Timer?
    private var lastState: String?
    private let defaults = UserDefaults.standard

    var manageTailscaleApp: Bool {
        get { defaults.object(forKey: "manageTailscaleApp") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "manageTailscaleApp"); objectWillChange.send() }
    }
    // PEER=name in the config file; the tailnet machine to ping for a health check.
    lazy var peer: String = {
        let text = (try? String(contentsOfFile: configFile, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") where line.hasPrefix("PEER=") {
            let v = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !v.isEmpty { return v }
        }
        return ""
    }()

    private var peerTimer: Timer?

    init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.load() }
        // Menu items close the menu when clicked, so keep the peer status fresh on our own.
        pingPeer()
        peerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.pingPeer() }
    }

    func load() {
        if let m = try? String(contentsOfFile: modeFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { mode = m }
        guard let data = FileManager.default.contents(atPath: stateFile),
              let s = try? JSONDecoder().decode(DaemonState.self, from: data) else {
            st = nil; return
        }
        if s != st { st = s }
        // campusd re-checks at least every 60 s; much older means it isn't running.
        stale = Date().timeIntervalSince1970 - s.checked > 180
        if s.state != lastState {
            transition(from: lastState, to: s.state); lastState = s.state
            // Give the tunnel a moment to come up, then re-check the peer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.pingPeer() }
        }
    }

    // Remembered across restarts of this menu bar app, so a campus -> normal
    // switch that happens while it isn't running still reopens Tailscale.
    private var lastDaemonState: String? {
        get { defaults.string(forKey: "lastDaemonState") }
        set { defaults.set(newValue, forKey: "lastDaemonState") }
    }

    private func transition(from: String?, to: String) {
        let previous = from ?? lastDaemonState
        if to != "offline" { lastDaemonState = to }   // offline is a blip, not a mode
        guard manageTailscaleApp else { return }
        if to == "campus" {
            NSRunningApplication.runningApplications(withBundleIdentifier: tailscaleAppID)
                .forEach { $0.terminate() }
        } else if previous == "campus", ["normal", "warp_manual", "stopped"].contains(to) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tailscaleAppID) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        }
    }

    func setMode(_ m: String) {
        do { try (m + "\n").write(toFile: modeFile, atomically: false, encoding: .utf8); mode = m }
        catch { alert("Couldn't change mode", "\(error.localizedDescription)\n\nIs CampusSwitch installed? Run install.sh with sudo.") }
    }

    func checkNow() {
        try? "\(Date().timeIntervalSince1970)\n".write(toFile: triggerFile, atomically: false, encoding: .utf8)
    }

    private var pinging = false

    func pingPeer() {
        guard !pinging, !peer.isEmpty else { return }
        pinging = true
        let peer = self.peer
        // Campus mode: the Homebrew tailscaled. Otherwise: the Tailscale Mac app's CLI.
        let campus = st?.state == "campus"
        let exe = campus ? tsCLI : "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        let args = (campus ? [tsSocket] : []) + ["ping", "-c", "1", "--timeout", "4s", peer]
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            var out = ""
            if (try? p.run()) != nil {
                p.waitUntilExit()
                out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            }
            let result = Model.describePong(out, peer: peer)
            DispatchQueue.main.async {
                let f = DateFormatter(); f.timeStyle = .short
                self.peerResult = "\(result) · \(f.string(from: Date()))"
                self.pinging = false
            }
        }
    }

    // "pong from server (100.x) via DERP(nue) in 145ms" -> "server: 145 ms via relay (nue)"
    static func describePong(_ out: String, peer: String) -> String {
        guard let line = out.split(separator: "\n").first(where: { $0.contains("pong from") }) else {
            return "\(peer): no reply"
        }
        let s = String(line)
        let ms = s.range(of: #"in (\d+)ms"#, options: .regularExpression)
            .map { s[$0].dropFirst(3).dropLast(2) }.map(String.init) ?? "?"
        if let r = s.range(of: #"DERP\((\w+)\)"#, options: .regularExpression) {
            return "\(peer): \(ms) ms via relay (\(s[r].dropFirst(5).dropLast()))"
        }
        return "\(peer): \(ms) ms direct"
    }

    func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logFile)) }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    // Presentation
    var icon: String {
        guard let s = st, !stale else { return "questionmark.circle" }
        switch s.state {
        case "campus": return "graduationcap.fill"
        case "normal": return "network"
        case "warp_failed": return "exclamationmark.triangle.fill"
        case "warp_manual": return "cloud.fill"
        case "offline": return "wifi.slash"
        default: return "questionmark.circle"
        }
    }
    var title: String {
        guard let s = st else { return "Service not running (run install.sh)" }
        if stale { return "Service not responding" }
        switch s.state {
        case "campus": return "Campus mode: Tailscale via WARP"
        case "normal": return "Normal: Tailscale app"
        case "warp_failed": return "Problem: WARP can't connect"
        case "warp_manual": return "WARP full tunnel (manual)"
        case "offline": return "Offline"
        case "stopped": return "Service stopped"
        default: return s.state
        }
    }
    var detail: String {
        guard let s = st else { return "" }
        let f = DateFormatter(); f.timeStyle = .short
        let since = f.string(from: Date(timeIntervalSince1970: s.since))
        return "\(s.reason) · since \(since)"
    }
}

struct MenuContent: View {
    @ObservedObject var model: Model

    var body: some View {
        Text(model.title)
        if !model.detail.isEmpty { Text(model.detail) }
        if let s = model.st, !s.iface.isEmpty {
            Text("\(s.service.isEmpty ? s.iface : s.service) · tailscaled \(s.tailscaled ? "running" : "stopped")")
        }
        Divider()
        Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
            Text("Automatic").tag("auto")
            Text("Always campus mode").tag("campus")
            Text("Always normal").tag("normal")
        }
        Button("Check now") { model.checkNow() }
        Divider()
        if !model.peer.isEmpty {
            Text(model.peerResult.isEmpty ? "\(model.peer): checking…" : model.peerResult)
        }
        Divider()
        Menu("More") {
            if !model.peer.isEmpty { Button("Re-check \(model.peer) now") { model.pingPeer() } }
            Toggle("Quit/reopen Tailscale app automatically", isOn: Binding(
                get: { model.manageTailscaleApp }, set: { model.manageTailscaleApp = $0 }))
            Button("Open log") { model.openLog() }
            Divider()
            Button("Quit menu bar icon (service keeps running)") { NSApp.terminate(nil) }
        }
    }
}

@main
struct CampusSwitchApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.icon)
        }
        .menuBarExtraStyle(.menu)
    }
}
