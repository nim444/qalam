#!/usr/bin/env bash
# Checks what building and running Qalam needs, and says how to fix what's missing.
# It only reads, except one thing: when it finds the Android SDK and android/local.properties
# doesn't exist yet, it writes that file (gitignored) with the SDK path.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
problems=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() {
  printf '  \033[31m✗\033[0m %s\n      → %s\n' "$1" "$2"
  problems=$((problems + 1))
}

echo "Mac"
ver="$(sw_vers -productVersion)"
if [ "${ver%%.*}" -ge 15 ]; then pass "macOS $ver"; else fail "macOS $ver" "Qalam needs macOS 15 or later"; fi
if command -v swift >/dev/null 2>&1; then
  sv="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"
  if [ "${sv%%.*}" -ge 6 ] 2>/dev/null; then pass "Swift $sv"; else fail "Swift $sv" "Swift 6 or later is needed: install or update Xcode, or run xcode-select --install"; fi
else
  fail "Swift not found" "xcode-select --install"
fi

echo "Android"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [ -d "$SDK/platforms" ]; then
  pass "Android SDK at $SDK"
  if ls "$SDK/platforms" | grep -q "android-36"; then pass "Android platform 36"; else
    fail "Android platform 36 missing" "Android Studio → Settings → Android SDK → tick Android 16 (API 36), or: \"$SDK/cmdline-tools/latest/bin/sdkmanager\" \"platforms;android-36\""
  fi
  if [ -n "$(ls "$SDK/build-tools" 2>/dev/null)" ]; then pass "Android build-tools"; else
    fail "Android build-tools missing" "\"$SDK/cmdline-tools/latest/bin/sdkmanager\" \"build-tools;36.0.0\""
  fi
  if [ ! -f "$ROOT/android/local.properties" ]; then
    echo "sdk.dir=$SDK" > "$ROOT/android/local.properties"
    pass "wrote android/local.properties (sdk.dir)"
  fi
else
  fail "Android SDK not found (looked in $SDK)" "Install Android Studio (it sets up the SDK), or brew install --cask android-commandlinetools and set ANDROID_HOME"
fi

JH="${JAVA_HOME:-}"
[ -z "$JH" ] && [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ] && JH="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
[ -z "$JH" ] && JH="$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)"
jv="$([ -n "$JH" ] && "$JH/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)"
if [ -n "$jv" ] && [ "$jv" -ge 17 ]; then pass "JDK $jv ($JH)"; else
  fail "No JDK 17 or later" "Install Android Studio (it bundles one), or: brew install --cask temurin@21"
fi

echo "Phone"
ADB="$(command -v adb || true)"
[ -z "$ADB" ] && [ -x "$SDK/platform-tools/adb" ] && ADB="$SDK/platform-tools/adb"
if [ -n "$ADB" ]; then
  pass "adb ($ADB)"
  phones=0
  for serial in $("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }'); do
    "$ADB" -s "$serial" shell getprop ro.build.characteristics | grep -q watch && continue
    model="$("$ADB" -s "$serial" shell getprop ro.product.model | tr -d '\r')"
    sdk="$("$ADB" -s "$serial" shell getprop ro.build.version.sdk | tr -d '\r')"
    if [ "$sdk" -ge 34 ] 2>/dev/null; then pass "phone $model ($serial), Android API $sdk"; else
      fail "phone $model ($serial) is on Android API $sdk" "Qalam needs Android 14 (API 34) or later"
    fi
    phones=$((phones + 1))
  done
  if [ "$phones" -eq 0 ]; then
    if "$ADB" devices | grep -q unauthorized; then
      fail "the phone hasn't allowed this Mac yet" "unlock the phone and tap Allow on the USB debugging prompt"
    else
      fail "no phone connected" "on the phone: Settings → About phone → Software information → tap Build number 7 times; then Settings → Developer options → USB debugging on; plug it in and tap Allow"
    fi
  fi
else
  fail "adb not found" "brew install --cask android-platform-tools (or install the Android SDK platform-tools)"
fi

echo
if [ "$problems" -eq 0 ]; then
  echo "Ready. Next: scripts/run.sh (builds both apps, installs them, starts Qalam)."
else
  echo "$problems thing(s) to fix first."
  exit 1
fi
