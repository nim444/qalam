#!/usr/bin/env bash
# M0 feel test in one command: build both sides, install + open the phone app on every attached
# phone (watches are skipped), then run the Mac receiver in the foreground (Ctrl-C to stop).
# Extra arguments go to qalam-m0, e.g. `scripts/m0.sh --display 1` or `--raw`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"

echo "› building the Mac receiver"
(cd "$ROOT/mac" && swift build -c release 2>&1 | grep -E "error|Compiling|Build complete" || true)

echo "› building the phone app"
(cd "$ROOT/android" && ./gradlew -q assembleDebug)
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"

for serial in $(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }'); do
  if adb -s "$serial" shell getprop ro.build.characteristics | grep -q watch; then continue; fi
  echo "› installing on $serial"
  adb -s "$serial" install -r "$APK" >/dev/null
  adb -s "$serial" shell am start -n ro.soluzy.qalam/.MainActivity >/dev/null
done

exec "$ROOT/mac/.build/release/qalam-m0" "$@"
