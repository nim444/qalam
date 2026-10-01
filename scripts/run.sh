#!/usr/bin/env bash
# Build and start everything: the Mac app (installed to /Applications) and the phone app
# (installed and opened on every attached phone; watches are skipped).
# Needs: Xcode command-line tools, the Android SDK, a JDK 17+, adb, USB debugging on the phone.
# scripts/doctor.sh checks all of that and says how to fix what's missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  [ -d "$JAVA_HOME" ] || JAVA_HOME="$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)"
fi
export JAVA_HOME
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="$(command -v adb || echo "$SDK/platform-tools/adb")"

echo "› Mac app"
"$ROOT/scripts/build-mac-app.sh" | tail -1

echo "› phone app"
(cd "$ROOT/android" && ./gradlew -q assembleDebug)
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
for serial in $("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }'); do
  if "$ADB" -s "$serial" shell getprop ro.build.characteristics | grep -q watch; then continue; fi
  echo "  installing on $serial"
  "$ADB" -s "$serial" install -r "$APK" >/dev/null
  "$ADB" -s "$serial" shell am start -n ro.soluzy.qalam/.MainActivity >/dev/null
done

# Only one receiver can own the port: stop an older Qalam or the qalam-m0 test tool.
for pid in $(pgrep -f "Qalam.app/Contents/MacOS/Qalam|qalam-m0" || true); do
  echo "  stopping the running receiver ($pid)"
  kill "$pid"
done
sleep 0.5

rm -rf /Applications/Qalam.app
cp -R "$ROOT/mac/build/Qalam.app" /Applications/
open /Applications/Qalam.app
echo "› Qalam is in the menu bar. Cursor mode needs Accessibility: menu → Allow Accessibility."
