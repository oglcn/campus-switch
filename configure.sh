#!/bin/zsh
# Writes ./config by asking a few questions.
#   ./configure.sh          change your settings, then: sudo ./install.sh
# install.sh runs this automatically on a first install.
set -euo pipefail
cd "${0:A:h}"

write_config() {  # peer, bypass entries...
  local peer=$1; shift
  {
    print "# CampusSwitch settings, written by configure.sh on $(date +%F). See config.example."
    print -n "EXTRA_BYPASS=("
    local b; for b in "$@"; do print -n " '$b'"; done
    print " )"
    print "PEER=$peer"
  } > config
}

# No terminal (e.g. scripted install): no extras, no health check.
if [[ ! -t 0 ]]; then
  write_config ""
  print "configure.sh: not interactive; wrote an empty config (edit ./config later)"
  exit 0
fi

# This file is loaded by a root service, so only allow plain hostnames.
valid_host() { [[ $1 =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' ]] }

ask_domain() {  # prompt -> prints "*.domain" or nothing
  local answer
  while true; do
    print -nu2 -- "$1"; read answer || answer=""
    answer=${answer## }; answer=${answer%% }; answer=${answer#\*.}; answer=${answer#.}
    [[ -z $answer ]] && return 0
    if valid_host "$answer"; then print -r -- "*.$answer"; return 0; fi
    print -u2 "  Please enter a plain domain like example.com"
  done
}

print "CampusSwitch setup (Enter skips any question)"
print

# 1. Peer to ping: list tailnet machines from whichever Tailscale is running.
peers=()
for cli in "/Applications/Tailscale.app/Contents/MacOS/Tailscale" \
           "/opt/homebrew/bin/tailscale --socket=/var/run/tailscaled-cli.socket"; do
  out=$(${=cli} status 2>/dev/null </dev/null) || continue   # </dev/null: don't eat typed answers
  peers=( ${(f)"$(print -r -- "$out" | awk 'NR>1 && /^100\./ { print $2 ($0 ~ /offline/ ? " (offline)" : "") }')"} )
  (( ${#peers} )) && break
done

peer=""
print "1) Which tailnet machine should the menu bar app ping to show the tailnet works?"
if (( ${#peers} )); then
  for i in {1..${#peers}}; do print "   $i. ${peers[$i]}"; done
else
  print "   (couldn't list your tailnet; is Tailscale running and logged in?)"
fi
while true; do
  print -n "   Number or name: "; read answer || answer=""
  answer=${answer// /}
  [[ -z $answer ]] && break
  if [[ $answer == <-> ]] && (( answer >= 1 && answer <= ${#peers} )); then
    peer=${peers[$answer]% (offline)}; break
  fi
  if valid_host "$answer"; then peer=$answer; break; fi
  print "   Please enter a number from the list or a machine name"
done
print

# 2. Hosts that should skip WARP in campus mode.
bypass=()
print "2) Your homelab domain, so it goes over Tailscale instead of WARP"
d=$(ask_domain "   e.g. home.example.com: "); [[ -n $d ]] && bypass+=("$d")
print
print "3) Your university's domain, so its sites still see a campus IP"
d=$(ask_domain "   e.g. example.edu: "); [[ -n $d ]] && bypass+=("$d")
print

write_config "$peer" "${bypass[@]}"
print "Saved ./config:"
sed 's/^/   /' config
