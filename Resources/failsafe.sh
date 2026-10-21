#!/bin/sh
# Caffeinate failsafe. launchd runs this every 30 s and at login.
# pmset disablesleep is system-wide and survives reboots, so if the app that turned it on is
# gone (crash, kill -9, reboot), put sleep and Low Power Mode back the way the session found them.
dir="${CAFFEINATE_SUPPORT_DIR:-$HOME/Library/Application Support/Caffeinate}"
sudo="${CAFFEINATE_SUDO:-/usr/bin/sudo}"
pmset_read="${CAFFEINATE_PMSET:-/usr/bin/pmset}"  # reads only; the sudo calls below name /usr/bin/pmset
marker="$dir/lid-session"
[ -f "$marker" ] || exit 0

value() { /usr/bin/sed -n "s/^$1=//p" "$marker" | /usr/bin/head -n 1; }

# disablesleep also turns off macOS's own low-battery sleep. The app stops at 15%, but a hung app
# doesn't, so at 10% on battery restore even while the app runs.
battery_low() {
    batt=$("$pmset_read" -g batt 2>/dev/null) || return 1
    case "$batt" in *"'Battery Power'"*) ;; *) return 1 ;; esac
    pct=$(printf '%s\n' "$batt" | /usr/bin/sed -n 's/.*[^0-9]\([0-9][0-9]*\)%;.*/\1/p' | /usr/bin/head -n 1)
    [ -n "$pct" ] && [ "$pct" -le 10 ]
}

pid=$(value pid)
until=$(value until)
case "$until" in '' | *[!0-9]*) until=0 ;; esac
case "$pid" in
    '' | *[!0-9]*) ;;
    # PIDs are reused after a reboot, so the process must also still be Caffeinate.
    # A live app past the session's hard deadline is hung or buggy: restore anyway.
    *) if /bin/ps -p "$pid" -o comm= 2>/dev/null | /usr/bin/grep -Eq '(^|/)Caffeinate$'; then
        { [ "$until" -eq 0 ] || [ "$(/bin/date +%s)" -lt "$until" ]; } && ! battery_low && exit 0
    fi ;;
esac

prior=$(value prior)
case "$prior" in 0 | 1) ;; *) prior=0 ;; esac
"$sudo" -n /usr/bin/pmset -a disablesleep "$prior" || exit 1

lpm=$(value lpm)
case "$lpm" in 0 | 1) "$sudo" -n /usr/bin/pmset -b lowpowermode "$lpm" || exit 1 ;; esac

/bin/rm -f "$marker"
