#!/bin/zsh
# Installs CampusSwitch. Run once:  sudo ./install.sh
set -euo pipefail
cd "${0:A:h}"

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }
USER_NAME=${SUDO_USER:?run via sudo from your own account}
USER_ID=$(id -u "$USER_NAME")
USER_HOME=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')

BASE="/Library/Application Support/CampusSwitch"
RUN="$BASE/run"
DAEMON=com.campusswitch.daemon
AGENT=com.campusswitch.menubar
AGENT_PLIST="$USER_HOME/Library/LaunchAgents/$AGENT.plist"

for f in /opt/homebrew/bin/tailscaled /opt/homebrew/bin/tailscale /usr/local/bin/warp-cli; do
  [[ -x $f ]] || { echo "Missing $f (brew install tailscale / install Cloudflare WARP)"; exit 1; }
done

echo "==> Building the menu bar app"
sudo -u "$USER_NAME" ./build.sh

echo "==> Stopping any previous install"
launchctl bootout "system/$DAEMON" 2>/dev/null || true
launchctl bootout "gui/$USER_ID/$AGENT" 2>/dev/null || true
pkill -x CampusSwitch 2>/dev/null || true   # also a copy opened by hand
# bootout returns before the old service has finished its cleanup; wait for it.
for i in {1..40}; do
  launchctl print "system/$DAEMON" >/dev/null 2>&1 || launchctl print "gui/$USER_ID/$AGENT" >/dev/null 2>&1 || break
  sleep 1
done

echo "==> Installing the service"
mkdir -p "$RUN"
install -o root -g wheel -m 755 daemon/campusd "$BASE/campusd"
install -o root -g wheel -m 644 daemon/com.campusswitch.tailscaled.plist "$BASE/"
if [[ -f config ]]; then
  install -o root -g wheel -m 644 config "$BASE/config"
elif [[ ! -f $BASE/config ]]; then
  install -o root -g wheel -m 644 config.example "$BASE/config"
  echo "    (no ./config found; installed config.example; edit $BASE/config with sudo)"
fi
install -o root -g wheel -m 644 daemon/$DAEMON.plist /Library/LaunchDaemons/
chown root:wheel "$BASE" "$RUN"; chmod 755 "$BASE" "$RUN"
# The menu bar app (running as you) writes these two files.
[[ -f $RUN/mode ]] || echo auto > "$RUN/mode"
touch "$RUN/trigger"
chown "$USER_NAME" "$RUN/mode" "$RUN/trigger"; chmod 644 "$RUN/mode" "$RUN/trigger"
touch /Library/Logs/CampusSwitch.log; chmod 644 /Library/Logs/CampusSwitch.log
for i in {1..5}; do
  launchctl bootstrap system /Library/LaunchDaemons/$DAEMON.plist 2>/dev/null && break
  (( i == 5 )) && { echo "Could not start the service (launchctl bootstrap failed)"; exit 1; }
  sleep 2
done

echo "==> Installing the menu bar app"
rm -rf /Applications/CampusSwitch.app
cp -R build/CampusSwitch.app /Applications/
chown -R "$USER_NAME" /Applications/CampusSwitch.app
sudo -u "$USER_NAME" mkdir -p "$USER_HOME/Library/LaunchAgents"
cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$AGENT</string>
	<key>ProgramArguments</key>
	<array><string>/Applications/CampusSwitch.app/Contents/MacOS/CampusSwitch</string></array>
	<key>RunAtLoad</key><true/>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF
chown "$USER_NAME" "$AGENT_PLIST"; chmod 644 "$AGENT_PLIST"
for i in {1..5}; do
  launchctl bootstrap "gui/$USER_ID" "$AGENT_PLIST" 2>/dev/null && break
  (( i == 5 )) && echo "Menu bar app didn't auto-start; open /Applications/CampusSwitch.app once"
  sleep 2
done

echo
echo "Installed. The menu bar icon should appear now and at every login."
echo "Log: /Library/Logs/CampusSwitch.log    Remove: sudo ./uninstall.sh"
