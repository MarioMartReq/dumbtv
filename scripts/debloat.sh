#!/usr/bin/env bash
# Uninstalls/disables the Amazon bloat and applies the privacy settings.
# Usage: ./scripts/debloat.sh [--dry-run] [-y]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_flags "$@"
need_device
is_fireos || die "this package list is for Fire OS; see docs/OTHER-TVS.md"
load_conf
check_keep_list

aps=$(list_of "$(fos user-apps.txt)")
for p in $REMOVE_EXTRA; do case " $aps " in *" $p "*) ;; *) aps="$aps $p";; esac; done

step "plan"
note "platform   $(fireos_name) (sdk $SDK), lists from ${DATA#$ROOT/}/$(basename "$(dirname "$(fos packages.txt)")")"
note "packages   $(list_of "$(fos packages.txt)" | wc -l | tr -d ' ')"
note "user apps  $(printf '%s' "$aps" | wc -w | tr -d ' ') (keeping: ${KEEP_APPS:-none extra})"
note "settings   $(list_of "$(fos settings.txt)" | wc -l | tr -d ' ')"
if [[ $DRY_RUN == 0 ]]; then
  note "these are uninstalled permanently (APKs live in /data):"
  for p in $aps; do
    keep_pkg "$p" && continue
    present "$p" || continue
    printf '    %-32s %s\n' "$(app_name "$p" || true)" "$p" >&2
  done
  note "Amazon system apps are disabled and can be restored by restore.sh"
  [[ $REINSTALL == 0 ]] &&
    note "this build has no 'cmd package install-existing': system apps are only disabled, never uninstalled"
  confirm "Remove ads/telemetry AND uninstall the apps listed above from $SERIAL?" || die "cancelled"
fi

if [[ $DRY_RUN == 1 ]]; then
  step "Amazon packages (dry-run)"
  for p in $(list_of "$(fos packages.txt)"); do
    protected_by_policy "$p" && { note "$p  SKIP (never-disable list)"; continue; }
    keep_pkg "$p" && { note "$p  SKIP (keep list)"; continue; }
    present "$p" && note "$p  would be removed or disabled"
  done
  step "third-party apps (dry-run)"
  for p in $aps; do
    protected_by_policy "$p" && { note "$p  SKIP (never-disable list)"; continue; }
    keep_pkg "$p" && { note "$p  SKIP (keep list)"; continue; }
    present "$p" && note "$p  would be uninstalled"
  done
  note "dry-run: nothing was changed"
  exit 0
fi

mkdir -p "$REPORT"
log="$REPORT/debloat.txt"
: > "$log"

step "Amazon packages"
removed=0; disabledn=0; protectedn=0; absent=0; suspect=0
for p in $(list_of "$(fos packages.txt)"); do
  if protected_by_policy "$p"; then
    printf '  %-46s SKIP (never-disable list)\n' "$p"; continue
  fi
  if keep_pkg "$p"; then
    printf '  %-46s SKIP (keep list)\n' "$p"; continue
  fi
  if ! present "$p"; then
    printf '  %-46s absent\n' "$p"; absent=$((absent+1)); continue
  fi
  # Uninstalling for user 0 is only undoable with install-existing (Android 8+).
  # Without it the app would only come back with a factory reset, so disable instead.
  if [[ $REINSTALL == 1 ]]; then
    out=$(acmd pm uninstall -k --user 0 "$p" | head -1)
    case $out in
      Success*) printf '  %-46s removed\n' "$p"; removed=$((removed+1))
                printf '%s\tremoved\n' "$p" >> "$log"; continue ;;
    esac
  fi
  out=$(acmd pm disable-user --user 0 "$p" | head -1)
  case $out in
    *disabled-user*) printf '  %-46s disabled\n' "$p"; disabledn=$((disabledn+1))
                     printf '%s\tdisabled\n' "$p" >> "$log" ;;
    *protected*)     printf '  %-46s PROTECTED\n' "$p"; protectedn=$((protectedn+1))
                     printf '%s\tprotected\n' "$p" >> "$log" ;;
    *)               printf '  %-46s SUSPECT: %s\n' "$p" "$out"; suspect=$((suspect+1))
                     printf '%s\tsuspect\t%s\n' "$p" "$out" >> "$log"
                     die "stopped at unexpected package failure; see ${log#$ROOT/}" ;;
  esac
done

step "third-party apps"
for p in $aps; do
  if protected_by_policy "$p"; then
    printf '  %-46s SKIP (never-disable list)\n' "$p"; continue
  fi
  if keep_pkg "$p"; then
    printf '  %-46s SKIP (keep list)\n' "$p"; continue
  fi
  if ! present "$p"; then
    printf '  %-46s absent\n' "$p"; continue
  fi
  out=$(acmd pm uninstall --user 0 "$p" | head -1)
  case $out in
    Success*) printf '  %-46s removed\n' "$p"; printf '%s\tremoved\n' "$p" >> "$log" ;;
    *)        printf '  %-46s kept: %s\n' "$p" "$out" ;;
  esac
done

step "processes that survived their own disable"
live=$(running_names)
for p in $(list_of "$(fos packages.txt)"); do
  printf '%s\n' "$live" | grep -qx "$p" || continue
  protected_by_policy "$p" && continue
  keep_pkg "$p" && continue
  uid=$(uid_of "$p")
  bg_off "$p"
  acmd am force-stop "$p" >/dev/null
  if [[ -n $uid && $uid -ge 10000 ]]; then
    acmd cmd netpolicy add restrict-background-blacklist "$uid" >/dev/null
  fi
  printf '  %-46s still running -> ops off, data blocked\n' "$p"
  printf '%s\tstarved\n' "$p" >> "$log"
done

step "privacy settings"
while read -r ns key value; do
  [[ -z ${ns:-} || $ns == \#* ]] && continue
  acmd settings put "$ns" "$key" "$value" >/dev/null
  printf '  %-46s %s\n' "$key" "$value"
done < <(list_of "$(fos settings.txt)" | sed 's/ = / /')

step "summary"
note "removed $removed · disabled $disabledn · protected $protectedn · absent $absent · suspect $suspect"
note "log: ${log#$ROOT/}"
[[ $suspect -gt 0 ]] && note "SUSPECT entries need a human look before continuing"

reboot_wait
note "home screen now: $(dev 'dumpsys activity activities' | grep -m1 mResumedActivity | sed 's/.*u0 //;s/}.*//')"
note "if that is not a home screen you can use, run ./scripts/restore.sh"
