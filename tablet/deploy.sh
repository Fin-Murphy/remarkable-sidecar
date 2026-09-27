#!/bin/sh
# Copies the tablet side to /home/root/rm2sidecar/ on the tablet (the only place we write).
# Usage: ./deploy.sh [EXTRA_FILE...]   Always copies the server and device/ scripts.
set -e
cd "$(dirname "$0")"
ssh root@10.11.99.1 'mkdir -p /home/root/rm2sidecar'
scp server/build/rm2sidecar device/run.sh device/start.sh device/session.batch "$@" \
    root@10.11.99.1:/home/root/rm2sidecar/
