#!/bin/sh
# Copies files to /home/root/rm2sidecar/ on the tablet (the only place we write).
# Usage: ./deploy.sh FILE...
set -e
cd "$(dirname "$0")"
ssh root@10.11.99.1 'mkdir -p /home/root/rm2sidecar'
scp run.sh "$@" root@10.11.99.1:/home/root/rm2sidecar/
