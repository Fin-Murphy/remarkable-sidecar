#!/bin/sh
# Starts a Sidecar session for the Mac's "Connect" (over ssh), unless one is already running.
# Prints "READY" once the server listens, or "ERROR: <reason>" (e.g. run.sh's start-limit guard).
# Also prints "WIFI <address>" (the tablet's current Wi-Fi address, if any) so the Mac can remember
# it as a fallback for when mDNS (remarkable.local) doesn't resolve.
cd /home/root/rm2sidecar || exit 1
wifi=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{split($2, a, "/"); print a[1]; exit}')
[ -n "$wifi" ] && echo "WIFI $wifi"
# One start.sh at a time, so a second Connect uses the first one's session instead of starting
# another. The lock lasts only as long as this script (its fd is closed for run.sh below).
exec 9>>.start.lock
i=0
until flock -n 9; do  # BusyBox flock has no -w
    [ $i -ge 30 ] && { echo "ERROR: another Connect is still starting the tablet"; exit 1; }
    sleep 1
    i=$((i + 1))
done
if netstat -tln | grep -q ' 127.0.0.1:9876 '; then echo READY; exit 0; fi
# A session that is ending (e.g. just after Disconnect) must bring xochitl back first; run.sh holds
# .session.lock until then, and refuses to start while it is held.
i=0
while ! flock -n .session.lock true && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
: > session.log  # truncate here, not in the background child, so we never read an old session's log
setsid ./run.sh -f session.batch >> session.log 2>&1 < /dev/null 9>&- &
i=0
while [ $i -lt 30 ]; do
    grep -q "link: listening" session.log && { echo READY; exit 0; }
    grep -qE "^run.sh: xochitl|not running|try again|usage|cannot listen" session.log && break
    sleep 1
    i=$((i + 1))
done
echo "ERROR: $(grep -vE 'keyboard|bin file|^run.sh: (battery|===)' session.log | tail -n 1)"
exit 1
