#!/usr/bin/env bash
# Build and start everything: the Mac app (installed to /Applications) and the phone app
# (installed and opened on every attached phone; watches are skipped).
# Needs: Xcode command-line tools, Android SDK + Android Studio's JDK, adb, USB debugging on the phone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"

echo "› Mac app"
"$ROOT/scripts/build-mac-app.sh" | tail -1

echo "› phone app"
(cd "$ROOT/android" && ./gradlew -q assembleDebug)
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
for serial in $(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }'); do
  if adb -s "$serial" shell getprop ro.build.characteristics | grep -q watch; then continue; fi
  echo "  installing on $serial"
  adb -s "$serial" install -r "$APK" >/dev/null
  adb -s "$serial" shell am start -n ro.soluzy.qalam/.MainActivity >/dev/null
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
