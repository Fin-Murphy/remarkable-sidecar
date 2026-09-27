#!/bin/sh
# Runs epaper Qt apps on the reMarkable 2 with xochitl stopped, and ALWAYS brings xochitl back:
#  - trap on EXIT/INT/TERM/HUP restarts it,
#  - each app is killed after its own time limit,
#  - an independent watchdog (own session) restarts xochitl if this script dies without cleanup.
# xochitl is stopped once and started once per invocation, however many apps run (batching).
#
# Usage (from /home/root/rm2sidecar/):
#   run.sh SECONDS BINARY [ARGS...]     one app
#   run.sh -f BATCHFILE                 several apps; each line: SECONDS BINARY [ARGS...]
if [ "$1" = "-f" ]; then
    BATCH=$(grep -v '^[[:space:]]*\(#\|$\)' "$2") || { echo "empty or missing batch file $2"; exit 2; }
else
    [ -n "$1" ] && [ -n "$2" ] || { echo "usage: run.sh SECONDS BINARY [ARGS...] | run.sh -f BATCHFILE"; exit 2; }
    BATCH="$*"
fi
TOTAL=0
for t in $(echo "$BATCH" | cut -d' ' -f1); do TOTAL=$((TOTAL + t)); done

battery=$(cat /sys/class/power_supply/*/capacity 2>/dev/null | head -n 1)
if [ "${battery:-0}" -le 30 ]; then echo "battery ${battery}% <= 30%, not running"; exit 3; fi

# xochitl.service allows 4 starts per 600 s (StartLimitBurst=4). A 5th start fails and triggers
# remarkable-fail.sh, which reboots -- and right after a firmware update (upgrade_available=1)
# falls back to the other root partition. So:
#  - never run while an update is pending,
#  - count xochitl's actual (re)starts in the last 600 s -- every restart we do is logged in
#    $STARTS, plus the boot start if uptime < 600 s -- and only run if our restart at the end
#    keeps the total at 3 or less (one below the limit, as margin).
if [ "$(fw_printenv -n upgrade_available 2>/dev/null)" != "0" ]; then
    echo "upgrade_available is not 0 (update pending?), not running"; exit 4
fi
STARTS=/home/root/rm2sidecar/.xochitl-starts
now=$(date +%s)
recent=$(awk -v since=$((now - 600)) '$1 > since' "$STARTS" 2>/dev/null | wc -l)
uptime_s=$(cut -d. -f1 /proc/uptime)
[ "$uptime_s" -lt 600 ] && recent=$((recent + 1))
if [ "$recent" -ge 3 ]; then
    oldest=$(awk -v since=$((now - 600)) '$1 > since' "$STARTS" 2>/dev/null | sort -n | head -n 1)
    echo "xochitl was started $recent times in the last 10 min; try again in $(( ${oldest:-$now} + 600 - now )) s"
    exit 5
fi

restore() {
    trap - EXIT INT TERM HUP
    # Our app must be gone before xochitl starts, or xochitl can't take the framebuffer lock.
    if [ -n "$APP" ] && kill -0 "$APP" 2>/dev/null; then kill "$APP"; sleep 3; kill -9 "$APP" 2>/dev/null; fi
    date +%s >> "$STARTS"
    systemctl start xochitl
    echo "run.sh: xochitl $(systemctl is-active xochitl)"
}
trap restore EXIT
trap 'exit 1' INT TERM HUP

# Independent watchdog: once this script is gone (for any reason), make sure xochitl runs.
SELF=$$
setsid sh -c "i=0; while kill -0 $SELF 2>/dev/null && [ \$i -lt $((TOTAL + 60)) ]; do sleep 1; i=\$((i+1)); done; systemctl is-active -q xochitl || { date +%s >> $STARTS; systemctl start xochitl; }" </dev/null >/dev/null 2>&1 &

echo "run.sh: battery ${battery}%, stopping xochitl for at most ${TOTAL}s"
systemctl stop xochitl
cd "$(dirname "$0")"
# Here-doc (not a pipe) so the loop runs in this shell and restore() sees $APP.
while read -r LIMIT BIN ARGS; do
    echo "run.sh: === $BIN $ARGS (at most ${LIMIT}s)"
    # shellcheck disable=SC2086
    QT_QUICK_BACKEND=epaper QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS="rotate=180:invertx" "$BIN" -platform epaper $ARGS </dev/null &
    APP=$!
    # Time limit: exits by itself shortly after the app does.
    ( i=0; while kill -0 $APP 2>/dev/null; do
        if [ $i -ge "$LIMIT" ]; then echo "run.sh: time limit, stopping app"; kill $APP; sleep 3; kill -9 $APP 2>/dev/null; fi
        sleep 1; i=$((i+1)); done ) &
    wait $APP
    echo "run.sh: app exited with $?"
    APP=
    sleep 2  # let the epaper framebuffer lock be released before the next app
done <<EOF_BATCH
$BATCH
EOF_BATCH
