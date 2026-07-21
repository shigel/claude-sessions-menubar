#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP="dist/ClaudeSessions.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS"

echo "==> Assembling .app bundle"
cp .build/release/ClaudeSessions "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

SIGN_IDENTITY="${CLAUDE_SESSIONS_SIGN_IDENTITY:-ClaudeSessions Dev Signer}"
echo "==> codesign with local self-signed identity: $SIGN_IDENTITY"
codesign --force --deep -s "$SIGN_IDENTITY" "$APP"

echo "==> zip"
ditto -c -k --keepParent "$APP" dist/ClaudeSessions.zip

echo "==> done: $APP and dist/ClaudeSessions.zip"
