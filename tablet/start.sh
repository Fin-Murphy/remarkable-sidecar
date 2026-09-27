#!/bin/sh
# Starts a Sidecar session for the Mac's "Connect" (over ssh), unless one is already running.
# Prints "READY" once the server listens, or "ERROR: <reason>" (e.g. run.sh's start-limit guard).
# Also prints "WIFI <address>" (the tablet's current Wi-Fi address, if any) so the Mac can remember
# it as a fallback for when mDNS (remarkable.local) doesn't resolve.
cd /home/root/rm2sidecar || exit 1
wifi=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{split($2, a, "/"); print a[1]; exit}')
[ -n "$wifi" ] && echo "WIFI $wifi"
if pidof rm2sidecar >/dev/null; then echo READY; exit 0; fi
: > session.log  # truncate here, not in the background child, so we never read an old session's log
setsid ./run.sh -f session.batch >> session.log 2>&1 < /dev/null &
i=0
while [ $i -lt 30 ]; do
    grep -q "link: listening" session.log && { echo READY; exit 0; }
    grep -qE "^run.sh: xochitl|not running|try again|usage|cannot listen" session.log && break
    sleep 1
    i=$((i + 1))
done
echo "ERROR: $(grep -vE 'keyboard|bin file|^run.sh: (battery|===)' session.log | tail -n 1)"
exit 1
