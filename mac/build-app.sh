#!/bin/sh
# Builds build/RM2Sidecar.app. Signs with your Apple Development identity if there is one, so
# Screen Recording / Accessibility grants survive rebuilds; otherwise signs ad hoc.
# Settings come from ../config.local (see ../config.example). RM2_HOST, RM2_WIFI_HOST and RM2_PORT
# are baked into the app (LSEnvironment), so they also apply when it's opened from Finder.
set -e
cd "$(dirname "$0")"
[ -f ../config.local ] && . ../config.local
swift build -c release
APP=build/RM2Sidecar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/RM2Sidecar "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
for key in RM2_HOST RM2_WIFI_HOST RM2_PORT; do
    eval "value=\${$key:-}"
    [ -n "$value" ] || continue
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:$key string $value" "$APP/Contents/Info.plist"
    echo "Baked in $key=$value"
done
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}
codesign --force --sign "${IDENTITY:--}" "$APP"
# Make Launch Services re-read the Info.plist (LSEnvironment is cached).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad hoc})"
