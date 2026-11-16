# CampusSwitch

Keeps [Tailscale](https://tailscale.com) working on networks that block it, such as campus Wi-Fi that filters `controlplane.tailscale.com` by hostname. It switches automatically and shows its state in the macOS menu bar.

- **Normal networks:** nothing changes. You use the Tailscale Mac app as usual.
- **Networks that block Tailscale:** [Cloudflare WARP](https://one.one.one.one/) runs as a local proxy, a Homebrew `tailscaled` connects through it, and the macOS web proxy points at WARP so your browser gets through too.

It never touches the routing table. If anything goes wrong, you lose the tailnet, not your internet.

## Why not just run the Tailscale app over WARP?

The Tailscale Mac app deliberately sends its own traffic around other VPN tunnels, straight out of the Wi-Fi interface, so the network's filter still sees and blocks it. It also ignores the macOS proxy setting. The open-source `tailscaled` does respect `HTTPS_PROXY`, so CampusSwitch runs that behind WARP's local proxy instead.

## Requirements

- macOS 13 or later on Apple Silicon (Homebrew in `/opt/homebrew`)
- [Cloudflare WARP](https://one.one.one.one/), signed in (`warp-cli` in `/usr/local/bin`)
- `brew install tailscale` (the CLI and `tailscaled`; it runs alongside the Tailscale Mac app)
- Xcode or the Command Line Tools (to build the menu bar app)

## Install

```bash
git clone https://github.com/oglcn/campus-switch.git
cd campus-switch
sudo ./install.sh
```

On a first install it asks three optional questions: which tailnet machine to ping as a health check (picked from a list of your machines), your homelab domain, and your university's domain. It then builds the menu bar app, installs the background service (starts at boot), and adds the menu bar app as a login item.

**Log in once:** the Homebrew `tailscaled` is a separate Tailscale device from the Mac app. The first time it runs in campus mode, log it in:

```bash
/opt/homebrew/bin/tailscale --socket=/var/run/tailscaled-cli.socket up
```

Then open the printed link. It shows up in your tailnet as a second machine.

## Configuration

Your answers are saved in `config` (zsh syntax; not committed, see `config.example`) and installed to `/Library/Application Support/CampusSwitch/config`:

| Setting | Meaning |
|---|---|
| `EXTRA_BYPASS=( … )` | Hosts that skip WARP in campus mode. Add your homelab domain so it goes over Tailscale, and your university's domain so its sites still see a campus IP. |
| `PEER=name` | A tailnet machine the menu bar app pings every 30 s as a health check. Empty hides it. |

To change it later, run `./configure.sh` (or edit `config` by hand), then `sudo ./install.sh` again. The service and the menu bar app read it only when they start.

## How it works

`campusd` (a root LaunchDaemon) checks every 5 seconds whether your network changed, and does a full check every 60 seconds:

1. No internet, or a captive portal: proxy off, so you can log in to the portal.
2. You turned on WARP's full tunnel yourself: it stays out of the way.
3. `controlplane.tailscale.com` reachable directly: **normal mode**.
4. Otherwise: **campus mode**. WARP goes to proxy mode on `127.0.0.1:40000`, `tailscaled` starts with `HTTPS_PROXY` set and accepts subnet routes, and the macOS web proxy is turned on.
5. If WARP can't connect: back to normal mode, retrying every 5 minutes.

### Menu bar

- **Status:** the current mode, why it was chosen, and a ping to your `PEER` every 30 seconds.
- **Mode:** Automatic, Always campus mode, or Always normal.
- **Retry now:** re-check immediately, skipping the 5-minute wait after a WARP failure.
- **Restart service…:** shown when the service isn't responding; asks for your admin password.
- **More ▸ Turn off switching:** back to normal mode, and the service stays idle until you choose **Turn on**. Survives reboots.
- **More ▸ Quit CampusSwitch:** turns switching off and removes the icon. Open CampusSwitch again and choose **Turn on** to resume.

It quits the Tailscale Mac app in campus mode and reopens it when you leave (you can turn this off under More). Logs: `/Library/Logs/CampusSwitch.log` (the service) and `/Library/Logs/CampusSwitch-tailscaled.log`.

To check what it would decide without changing anything:

```bash
zsh daemon/campusd probe
```

## Limitations

- No exit node in campus mode. Internet traffic goes through WARP, and only tailnet traffic goes through Tailscale. Exit nodes need routing-table changes, which proved fragile when WARP or the network changes.
- Apps that ignore the macOS proxy (some games, CLI tools) go out directly in campus mode.
- In campus mode every connection goes through a relay (DERP) over WARP, so expect relay latency.
- If the network also blocks WARP, campus mode can't work. The menu shows a warning and you stay on plain Wi-Fi.
- Check your network's acceptable use policy before using this.

## Uninstall

```bash
sudo ./uninstall.sh
```

It switches back to normal mode before removing itself. The Homebrew `tailscaled` login in `/Library/Tailscale-cli` is kept.
