#!/bin/sh
# Copies the tablet side to /home/root/rm2sidecar/ on the tablet (the only place we write).
# Usage: ./deploy.sh [EXTRA_FILE...]   Always copies the server and the device/ scripts.
# The tablet's address comes from ../config.local (RM2_HOST); see ../config.example.
set -e
cd "$(dirname "$0")"
[ -f ../config.local ] && . ../config.local
HOST=${RM2_HOST:-10.11.99.1}
ssh "root@$HOST" 'mkdir -p /home/root/rm2sidecar'
scp server/build/rm2sidecar device/run.sh device/start.sh device/session.batch "$@" \
    "root@$HOST:/home/root/rm2sidecar/"
