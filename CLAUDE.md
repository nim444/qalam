# Qalam: instructions for Claude Code

Qalam turns a Samsung Galaxy phone's S Pen into a pen tablet for the Mac.
- **Cursor mode:** hover moves the cursor, the tip clicks.
- **Ink mode:** the pen writes on a transparent overlay that screen recordings capture.

There are two apps:
- a Kotlin Android app (`android/`)
- a Swift menu-bar app (`mac/`)

They talk over Wi-Fi (UDP + Bonjour) with a USB fallback (`adb reverse`). They pair once by
comparing a 6-digit code, and every frame is encrypted after that. The user-facing overview
is in `README.md`.

## When someone asks you to set Qalam up

Walk them through it one step at a time. Explain what each step is for, run what you can, and
ask before anything that installs software or replaces an app.

1. **Check the tools:** run `scripts/doctor.sh`. It checks macOS 15+, Swift 6+, the Android
   SDK (platform 36), a JDK 17+, adb and a connected phone on Android 14+, and prints a fix for
   each ✗.
   - Help with the fixes, but ask first. Installing Android Studio or running `brew install`
     is their call.
   - The doctor writes `android/local.properties` itself when it finds the SDK.
2. **Turn on USB debugging on the phone** (needed to install the app and for the USB fallback):
   - Settings → About phone → Software information → tap **Build number** 7 times.
   - Settings → Developer options → turn on **USB debugging**.
   - Plug the phone in and tap **Allow** on the phone.
   - `scripts/doctor.sh` should then list the phone.
3. **Build and install:** run `scripts/run.sh`. First tell them what it does:
   - builds both apps
   - **replaces `/Applications/Qalam.app`** and stops a Qalam (or `qalam-m0`) that's running
   - installs and opens the app on every attached phone (watches are skipped)
   - The first Gradle build downloads dependencies and takes a few minutes.
4. **Mac permissions:**
   - **Accessibility** is needed for Cursor mode only, because moving the cursor means posting
     mouse events. In the Qalam menu choose **Allow Accessibility…**, then switch Qalam on in
     System Settings → Privacy & Security → Accessibility.
   - The app is ad-hoc signed, so **macOS forgets this grant after every rebuild**. If Cursor
     mode stops moving the cursor after a rebuild, remove Qalam from the list and add it again.
   - Ink mode needs no permission.
   - If macOS asks about local network access or incoming connections, the answer is
     **Allow**.
5. **Pair (the user does this):**
   - On the Mac: Qalam's menu-bar icon → **Pair a phone…**.
   - On the phone: open Qalam and tap the Mac in the list. **Mac on the USB cable** and
     **Enter the Mac's address…** are there too.
   - Both screens show a 6-digit code. If they match, click **Pair** on the Mac.
6. **First use:**
   - The strip on the right of the phone switches **Cursor / Ink**, the tool (pen,
     highlighter, laser, eraser), colour and size, has undo and clear, and **Display** picks
     the screen.
   - Holding the side button while writing erases.
   - Mac hotkeys: ⌃⌥I toggles ink, ⌃⌥Z undo, ⌃⌥C clear, ⌃⌥L laser, ⌃⌥D next display.

### Troubleshooting

| Symptom | What to check |
|---|---|
| The phone lists no Mac | Both on the same Wi-Fi? Guest networks and "client isolation" block devices from seeing each other. Use **Mac on the USB cable**, or **Enter the Mac's address…** (on the Mac: System Settings → Wi-Fi → Details) |
| "The Mac didn't answer" while pairing | The Mac's **Pair a phone…** window must be open while pairing. If the macOS firewall is on, Qalam must be allowed |
| Pairing worked once, now nothing connects | The phone app was reinstalled or its data cleared, so pair again (the Mac replaces the old entry with the same phone name). The Mac's menu shows "⚠ An unpaired phone is trying to connect" in this case |
| The cursor doesn't move in Cursor mode | Accessibility (step 4); after a rebuild, remove Qalam from the list and add it again |
| The S Pen button opens Samsung's Air command | Turn Air command off: Settings → Advanced features → S Pen |
| The USB fallback isn't used | USB debugging on and allowed; the Mac's menu should say "USB fallback: ready"; `adb reverse --list` should show `tcp:47474` |
| "Qalam can't listen on port 47474" | Another Qalam or `qalam-m0` is running; quit it first |
| The phone app closes | `adb logcat -d -b crash \| grep -A 25 ro.soluzy.qalam` shows why |

## Working on the code

```
android/app/src/main/kotlin/ro/soluzy/qalam/
  MainActivity.kt   pad + strip + pairing screen; the Mac owns the state, the strip follows pongs
  PadView.kt        S Pen input → pen payloads; draws the pad and the local copy of the ink
  LocalInk.kt       the phone's copy of the ink (same rules as mac/Sources/Qalam/Ink.swift)
  Link.kt           Wi-Fi (UDP, Bonjour by Mac id) + USB (TCP via adb reverse), sealing, failover
  Pairer.kt, PairingStore.kt, PairingPanel.kt   pairing (phone side), key wrapped by the Keystore
  Crypto.kt, Wire.kt                            X25519 / HKDF / AES-GCM, the wire format
android/app/src/test/.../CryptoTest.kt          JVM tests against vectors made from the spec
mac/Sources/QalamCore/   Wire, Secure (Gate: open/seal/replay), Pairing (store + responder),
                         Receiver, Displays, Injector (CGEvent cursor), Stats, Adb
mac/Sources/Qalam/       the menu-bar app: Controller, Ink (overlay), StatusMenu, PairingWindow, Hotkeys
mac/Sources/qalam-m0/    command-line receiver that logs link quality (uses the same pairings)
docs/                    research.md, design.md, protocol.md (the wire format: the contract)
scripts/                 doctor.sh, run.sh, build-mac-app.sh, make-icon.swift
```

**Build and test:**

```bash
cd mac && swift build -c release                                # library, app, qalam-m0
scripts/build-mac-app.sh                                        # mac/build/Qalam.app
cd android && ./gradlew assembleDebug :app:testDebugUnitTest    # APK + crypto tests
```

**Rules:**
- **`docs/protocol.md` is the contract.** Change the wire format there first, then in both
  `Wire.swift` / `Secure.swift` / `Pairing.swift` and `Wire.kt` / `Crypto.kt` / `Link.kt` /
  `Pairer.kt`.
  - The phone and the Mac must stay in step: an old phone app can't talk to a new Mac.
  - For crypto changes, regenerate the vectors in `CryptoTest.kt` from the spec with an
    independent library (Python `cryptography` was used), and test the Mac against a Python
    phone written from the spec.
- **No dependencies.**
  - The Android app uses the platform SDK only, with JUnit for tests.
  - The Mac app uses Apple frameworks only (AppKit, Network, CryptoKit) and Swift 5 language
    mode.
  - Ask before adding any dependency.
- **Testing next to a running Qalam:**
  - Use a second instance: `QALAM_PORT=47480 mac/.build/release/Qalam`. It gets its own port,
    a temporary pairing file, and no Bonjour, so phones never find it.
  - `QALAM_TEST_AUTOPAIR=1` makes that test instance accept the first pairing code by itself.
    It works only together with `QALAM_PORT`.
- **Be careful on the user's machine:**
  - Never stop the user's Qalam by name (`pkill`). Stop only processes you started, by PID.
  - Never screen-capture the user's display. Ask them for screenshots or recordings.
  - Never print or commit pairing keys: `~/Library/Application Support/Qalam/pairings.json`
    and the phone's app data.
- **Never commit** `android/local.properties`, keystores, `mac/.build/`, `mac/build/` or
  Android `build/` outputs.
- **Style:** comments say *why*. User-facing text is plain, short English.

## Releases

Not set up yet. To publish downloads you need:
- a zipped `Qalam.app`: ad-hoc signed, not notarized, so users right-click → Open the first
  time
- an APK signed with a release key that is kept out of the repo
