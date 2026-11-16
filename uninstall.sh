#!/bin/zsh
# Removes CampusSwitch and restores normal networking:  sudo ./uninstall.sh
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }
USER_NAME=${SUDO_USER:?run via sudo from your own account}
USER_ID=$(id -u "$USER_NAME")
USER_HOME=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')
BASE="/Library/Application Support/CampusSwitch"

echo "==> Stopping the menu bar app"
launchctl bootout "gui/$USER_ID/com.campusswitch.menubar" 2>/dev/null
pkill -x CampusSwitch 2>/dev/null
rm -f "$USER_HOME/Library/LaunchAgents/com.campusswitch.menubar.plist"
rm -rf /Applications/CampusSwitch.app

echo "==> Stopping the service (it switches back to normal mode on the way out)"
launchctl bootout system/com.campusswitch.daemon 2>/dev/null
launchctl bootout system/com.campusswitch.tailscaled 2>/dev/null
rm -f /Library/LaunchDaemons/com.campusswitch.daemon.plist

# Belt and braces, in case the service wasn't running.
if [[ -f $BASE/run/proxy_services ]]; then
  while IFS= read -r svc; do
    [[ -n $svc ]] || continue
    networksetup -setsecurewebproxystate "$svc" off
    networksetup -setwebproxystate "$svc" off
  done < "$BASE/run/proxy_services"
fi
rm -rf "$BASE"

echo "Removed. Logs kept in /Library/Logs/CampusSwitch*.log."
echo "Your Homebrew tailscale login (/Library/Tailscale-cli) is untouched."
