#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> build"
bash scripts/build-app.sh

echo "==> stop running instance (if any)"
pkill -f "ClaudeSessions.app/Contents/MacOS/ClaudeSessions" 2>/dev/null || true
sleep 1

echo "==> install to /Applications"
rm -rf /Applications/ClaudeSessions.app
cp -R dist/ClaudeSessions.app /Applications/ClaudeSessions.app

echo "==> launch"
open /Applications/ClaudeSessions.app
sleep 1
ps aux | grep -i "ClaudeSessions.app/Contents/MacOS/ClaudeSessions" | grep -v grep

echo "==> done"
