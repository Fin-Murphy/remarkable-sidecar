#!/bin/sh
# Builds build/RM2Sidecar.app. Signs with your Apple Development identity if there is one, so
# Screen Recording / Accessibility grants survive rebuilds; otherwise signs ad hoc.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/RM2Sidecar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/RM2Sidecar "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad hoc})"
