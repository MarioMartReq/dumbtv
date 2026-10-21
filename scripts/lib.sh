#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts; not meant to be run directly.
# Must stay bash 3.2 compatible: that is what /usr/bin/env bash is on macOS.

ADB=${ADB:-adb}
DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DATA="$ROOT/data"
REPORT="$ROOT/report"
CONF=${CONF:-$ROOT/dumbtv.conf}
# Both names are accepted; ADB_SERIAL is what the docs tell people to set.
SERIAL=${SERIAL:-${ADB_SERIAL:-}}
# Android API level of the TV, read by need_device. 25 = Fire OS 6, 28 = Fire OS 7, 30 = Fire OS 8.
SDK=${SDK:-0}
# 1 when the TV has `cmd package install-existing`, i.e. an uninstalled system app can come back.
REINSTALL=${REINSTALL:-0}

# Preferences written by scripts/configure.sh. Absent file = defaults: keep
# nothing extra, PRIME=1, LAUNCHER=1, DNSFILTER=1, SYSTEM_DNS=0.
load_conf() {
  KEEP_APPS=${KEEP_APPS:-}
  REMOVE_EXTRA=${REMOVE_EXTRA:-}
  PRIME=${PRIME:-1}
  LAUNCHER=${LAUNCHER:-1}
  DNSFILTER=${DNSFILTER:-1}
  SYSTEM_DNS=${SYSTEM_DNS:-0}
  [[ -f $CONF ]] && source "$CONF"
  KEEP_APPS=${KEEP_APPS:-}; REMOVE_EXTRA=${REMOVE_EXTRA:-}
  PRIME=${PRIME:-1}; LAUNCHER=${LAUNCHER:-1}; DNSFILTER=${DNSFILTER:-1}
  SYSTEM_DNS=${SYSTEM_DNS:-0}
}

keep_pkg() {
  local k
  for k in $KEEP_APPS; do [[ $k == "$1" ]] && return 0; done
  return 1
}

# Keep entries must name an installed app or a removal candidate, so typos fail safely.
check_keep_list() {
  local k known
  [[ -z $KEEP_APPS ]] && return 0
  known=$(list_of "$(fos packages.txt)" | awk '{print $1}')
  known="$known $(list_of "$(fos user-apps.txt)" | awk '{print $1}') $REMOVE_EXTRA"
  for k in $KEEP_APPS; do
    printf '%s\n' "$known" | tr ' ' '\n' | grep -qx "$k" || present "$k" ||
      die "keep list entry '$k' is neither installed nor listed for removal (typo?)"
  done
}

step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*" >&2; }
ask_note() { printf '  %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

dev()  { "$ADB" -s "$SERIAL" shell "$@" 2>&1 </dev/null; }
# Legacy adbd returns CRLF; normalize single-line replies before comparing them.
dev1() { dev "$@" | head -1 | tr -d '\r'; }

# A dropped connection must not look like "package absent".
dev_ok() {
  local out
  out=$(dev "$@") || return 1
  printf '%s\n' "$out" | grep -qiE "^error: (device|closed|no devices)|device '[^']*' not found" &&
    die "device $SERIAL stopped responding — reconnect and re-run"
  printf '%s\n' "$out"
}

# Device command that honours --dry-run. The dry-run line goes to stderr so a
# caller's >/dev/null cannot hide it.
acmd() {
  if [[ $DRY_RUN == 1 ]]; then note "[dry-run] $*"; return 0; fi
  dev "$@"
}

confirm() {
  [[ $ASSUME_YES == 1 ]] && return 0
  printf '%s [y/N] ' "$1" >&2
  read -r reply
  case $reply in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

parse_flags() {
  for a in "$@"; do
    case $a in
      --dry-run) DRY_RUN=1 ;;
      -y|--yes)  ASSUME_YES=1 ;;
      *) die "unknown flag: $a" ;;
    esac
  done
}

need_device() {
  command -v "$ADB" >/dev/null || die "adb not found in PATH"
  "$ADB" start-server >/dev/null 2>&1
  if [[ -z $SERIAL ]]; then
    local found count
    found=$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')
    [[ -z $found ]] && die "no adb device. Enable ADB debugging on the TV, then: adb connect <tv-ip>:5555"
    count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
    [[ $count -gt 1 ]] && die "several devices attached; set ADB_SERIAL to the one you mean: $(printf '%s' "$found" | tr '\n' ' ')"
    SERIAL=$(printf '%s\n' "$found" | head -1)
  fi
  dev getprop ro.build.version.sdk >/dev/null || die "device $SERIAL is not responding"
  SDK=$(dev1 getprop ro.build.version.sdk | tr -d '\r')
  case $SDK in ''|*[!0-9]*) SDK=0 ;; esac
  dev 'cmd package help' | grep -q install-existing && REINSTALL=1 || REINSTALL=0
}

# Data file for this Fire OS generation. Fire OS 6 (Android 7.1) has its own lists in
# data/fireos6/; a file missing there falls back to the Fire OS 7/8 one in data/fireos/.
# Before need_device has run (SDK=0) this is always the Fire OS 7/8 file.
fos() {
  if [[ $SDK -gt 0 && $SDK -lt 28 && -f $DATA/fireos6/$1 ]]; then printf '%s' "$DATA/fireos6/$1"
  else printf '%s' "$DATA/fireos/$1"; fi
}

fireos_name() {
  if [[ $SDK -ge 30 ]]; then echo "Fire OS 8"
  elif [[ $SDK -ge 28 ]]; then echo "Fire OS 7"
  elif [[ $SDK -ge 22 ]]; then echo "Fire OS 6"
  else echo "Fire OS 5 or older (unsupported)"; fi
}

# Background execution off/on. RUN_ANY_IN_BACKGROUND only exists from Android 9; on
# Fire OS 6 appops rejects it, so only RUN_IN_BACKGROUND is set there.
bg_off() {
  acmd appops set "$1" RUN_IN_BACKGROUND ignore >/dev/null 2>&1
  [[ $SDK -ge 28 ]] && acmd appops set "$1" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1
  return 0
}
bg_on() {
  acmd appops set "$1" RUN_IN_BACKGROUND allow >/dev/null 2>&1
  [[ $SDK -ge 28 ]] && acmd appops set "$1" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1
  return 0
}

# Names of running processes. Fire OS 6 ships the old toolbox ps, which answers
# `ps -A -o NAME` with "bad pid '-A'"; its last column is the process name.
running_names() {
  local out
  out=$(dev 'ps -A -o NAME' | tr -d '\r')
  if printf '%s\n' "$out" | grep -q "bad pid"; then
    dev ps | tr -d '\r' | awk 'NR>1 {print $NF}'
  else
    printf '%s\n' "$out"
  fi
}

is_fireos()  { case $(dev1 getprop ro.product.manufacturer) in Amazon*) return 0 ;; *) return 1 ;; esac; }
gateway() {
  local gw
  gw=$(dev 'ip route show table all' \
    | awk '/^default/ && / via / && !/linkdown/ && !/ dev tun/ {
             for (i=1;i<=NF;i++) if ($i=="via") { print $(i+1); exit }
           }')
  [[ -z $gw ]] && gw=$(dev 'ip route show table all' \
    | awk '/^default/ && / via / && !/ dev tun/ {
             for (i=1;i<=NF;i++) if ($i=="via") { print $(i+1); exit }
           }')
  [[ -z $gw ]] && gw=$(dev 'dumpsys connectivity' | sed -n 's/.*ServerAddress: \([0-9.]*\).*/\1/p' | head -1)
  [[ -z $gw ]] && gw=$(dev 'getprop dhcp.wlan0.gateway' | tr -d '\r')
  printf '%s' "$gw"
}
uid_of()     { dev "dumpsys package $1" | sed -n 's/.*userId=\([0-9]*\).*/\1/p' | head -1; }
present()    { dev_ok "pm path $1" | grep -q '^package:'; }

reboot_wait() {
  note "rebooting the TV"
  dev reboot >/dev/null 2>&1 || true
  sleep 45
  local i
  for i in $(seq 1 30); do
    "$ADB" connect "$SERIAL" >/dev/null 2>&1 || true
    if [[ $(dev1 getprop sys.boot_completed) == 1 ]]; then
      note "booted"
      return 0
    fi
    sleep 5
  done
  die "device did not report boot_completed; check the TV by hand before running anything else"
}

# A network adb session can drop when the TV's network changes under it (an app that
# holds the VPN being replaced). Brings it back, or stops the run.
adb_reconnect() {
  local i
  for i in $(seq 1 12); do
    [[ $("$ADB" -s "$SERIAL" get-state 2>/dev/null) == device ]] && return 0
    [[ $SERIAL == *:* ]] && "$ADB" connect "$SERIAL" >/dev/null 2>&1
    sleep 3
  done
  die "lost adb to $SERIAL; check the TV is on, then run this again"
}

list_of() { sed 's/#.*//; s/[[:space:]]*$//' "$1" | awk 'NF'; }
# Compare on the first field: list entries carry trailing spaces after comments
# are stripped, and an exact match would silently fail to protect anything.
protected_by_policy() { list_of "$(fos never-disable.txt)" | awk '{print $1}' | grep -qx "$1"; }

# App name for a package, from data/apps.txt. Names may contain spaces, so match
# the package anywhere in the line and keep whatever precedes it.
app_name() {
  awk -v p="$1" 'index($0,p)==0 {next} {n=substr($0,1,index($0,p)-1); sub(/[[:space:]]+$/,"",n); print n; exit}' \
    "$DATA/apps.txt" 2>/dev/null
}
