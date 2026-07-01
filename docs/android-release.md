# Android APK release & the "invalid APK" problem on e-ink tablets

Locked-down e-ink firmwares (iFLYTEK AINOTE, some Onyx Boox, etc.) are much
pickier about APKs than a normal phone. When one of them refuses to install our
APK with *"invalid APK" / "package appears to be invalid" / "应用未安装"*, it is
almost always one of the causes below. This file is the checklist so we don't
re-diagnose it from scratch every time.

## TL;DR — what a valid APK for these devices needs

1. **Legacy native-lib packaging** (`useLegacyPackaging = true` → compressed `.so`
   + `extractNativeLibs=true`). ← **the cause of the AINOTE 2 failure.** Modern
   Flutter/AGP stores native libs uncompressed and page-aligned; the AINOTE
   installer rejects that layout as "package appears to be invalid".
2. **A stable signing key** — the same key for every build. A per-build key makes
   the device reject upgrades over an existing copy.
3. **A v1 (JAR) signature**, in addition to v2/v3. ← the original (first) bug.
4. A `targetSdkVersion` the firmware knows (we pin 34 = Android 14).
5. An ABI the device supports — we ship `arm64-v8a` + `armeabi-v7a` + `x86_64`.
6. To be downloaded **intact** onto the device.

All six are enforced in `android/app/build.gradle.kts` + guarded in `release.yml`.

## How to diagnose, fast

Download the *exact* asset the device gets and inspect it on a real machine —
don't trust "it built fine":

```bash
# grab the published asset
curl -sL -o einkreader.apk \
  "$(curl -sL https://api.github.com/repos/xdamman/einkreader/releases/latest \
     | grep browser_download_url | grep '\.apk' | head -1 | cut -d'"' -f4)"

# 1. signatures — v1 MUST be true.
# Use --min-sdk-version 23, NOT 24: APK Signature Scheme v2 starts at API 24, and
# apksigner reports "v1 scheme: false" at min-sdk 24+ even when a v1 signature IS
# present (it just isn't *needed* in that range). At 23 it actually checks v1.
apksigner verify --verbose --min-sdk-version 23 einkreader.apk | grep "scheme"

# 2. sdk levels + ABIs
aapt dump badging einkreader.apk | grep -E "sdkVersion|targetSdk|native-code"
```

`apksigner` / `aapt` live in `$ANDROID_SDK_ROOT/build-tools/<version>/`. They
need a JRE on `PATH` (`export PATH="$(/usr/libexec/java_home)/bin:$PATH"` on
macOS, or point at Android Studio's bundled JBR).

A healthy build looks like:

```
Verified using v1 scheme (JAR signing): true     <-- non-negotiable
Verified using v2 scheme (APK Signature Scheme v2): true
Verified using v3 scheme (APK Signature Scheme v3): true
sdkVersion:'24'
targetSdkVersion:'34'
native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'
```

## Cause 0 — uncompressed native libs  *(what actually broke the AINOTE 2)*

The symptom is **"App not installed as package appears to be invalid"** — a
*parse* failure, and it persists no matter the signing key, `targetSdk`,
`compileSdk`, or download method. That combination points here.

Newer Flutter/AGP defaults to `useLegacyPackaging = false`: native `.so`
libraries are stored **uncompressed and page-aligned** in the APK
(`android:extractNativeLibs="false"`). Stock Android handles this; the AINOTE 2's
locked-down `PackageParser` does not, and rejects the whole APK as invalid. Older
Flutter defaulted to the legacy (compressed) layout, which is why an earlier beta
installed and later builds didn't.

Confirm it on a suspect APK — the native libs should be `Defl` (compressed), not
`Stored`, and `extractNativeLibs` should be true:

```bash
unzip -v app.apk | grep 'lib/.*\.so'                              # want Defl, not Stored
aapt dump xmltree app.apk AndroidManifest.xml | grep extractNativeLibs   # want 0xffffffff
```

Fix, in `android/app/build.gradle.kts` (inside `android { }`):

```kotlin
packaging {
    jniLibs {
        useLegacyPackaging = true
    }
}
```

This also roughly halves the APK (compressed libs): our build went 58.6 MB → 26.7
MB. CI fails the release if `extractNativeLibs` is ever not-true.

## Cause 1 — missing v1 (JAR) signature  *(the original incident)*

Android Gradle Plugin **drops the v1 signature by default when `minSdk >= 24`**,
relying on v2/v3 alone. Old/locked-down firmwares only understand v1 and reject
a v2/v3-only APK as invalid.

Fix lives in `android/app/build.gradle.kts` — the signing config force-enables
all three schemes:

```kotlin
signingConfigs {
    getByName("debug") {
        enableV1Signing = true   // <-- the line that must never be removed
        enableV2Signing = true
        enableV3Signing = true
    }
}
```

> We sign release builds with the **debug** key on purpose so anyone can build an
> installable APK without our private keystore. If we ever add a real release
> keystore, it must carry the same three `enableVxSigning` flags.

This is now enforced: `release.yml` runs `apksigner verify` after the build and
**fails the release if the v1 scheme is missing**, so this specific regression
can't ship again silently.

## Cause 2 — `targetSdkVersion` newer than the firmware

A modern Flutter pins `targetSdkVersion` to the latest API (e.g. 36 / Android
16). A device on Android 14 with a customised OEM `PackageInstaller` can reject
an APK that targets an SDK it has never heard of — again surfaced as a generic
"invalid APK" parse error rather than a useful message.

If signatures check out but the device still refuses the APK, pin the target to
the newest Android the target devices actually run (currently the AINOTE 2 is
**Android 14 = API 34**) in `android/app/build.gradle.kts`:

```kotlin
defaultConfig {
    targetSdk = 34   // pin: AINOTE 2 firmware is Android 14; SDK 36 can be rejected
}
```

Leave `minSdk` low (24) — that only sets the *floor*, so it never hurts
compatibility.

## Cause 3 — release signed with a different key each build  *(the real recurrence)*

If the tablet already has an older copy of the app installed, Android refuses to
install a new APK **signed by a different key** — surfaced on locked-down
firmwares as a generic "invalid APK". This is easy to trigger by accident:

- a **local** `flutter build apk` signs with *your* `~/.android/debug.keystore`,
- but **CI has no keystore**, so Gradle auto-generates a **fresh random debug
  keystore on every runner** — a different signer each time.

So the first (local) build installs fine, and every GitHub build afterward is
rejected. Diagnose by comparing the signing certificate of the working APK and
the failing one:

```bash
apksigner verify --print-certs some.apk | grep "SHA-256"
```

Different `SHA-256` digests ⇒ different keys ⇒ this is your problem.

**Fix:** sign every build — local and CI — with **one stable key**. We store the
project's debug keystore as GitHub secrets; CI decodes it into
`android/key.properties` + `android/app/release.keystore` (both git-ignored), and
`android/app/build.gradle.kts` uses it for the `release` build type, falling back
to the debug key locally. Because the secret holds the *same* debug keystore your
machine uses, local and CI builds share one identity and upgrade cleanly.

The signing job in `release.yml` fails a tagged build if the keystore secret is
missing, and the verify step fails if the APK isn't signed with the expected
certificate `SHA-256` (`8fdf1f…`) — so a key regression can't ship silently.

### Setting up the signing secrets (one-time)

```bash
base64 -i ~/.android/debug.keystore | pbcopy   # keystore, base64-encoded
gh secret set ANDROID_KEYSTORE_BASE64 --repo xdamman/einkreader   # paste it
gh secret set ANDROID_KEYSTORE_PASSWORD --repo xdamman/einkreader --body android
gh secret set ANDROID_KEY_ALIAS       --repo xdamman/einkreader --body androiddebugkey
gh secret set ANDROID_KEY_PASSWORD    --repo xdamman/einkreader --body android
```

(The debug keystore's password is the well-known `android` / alias
`androiddebugkey` — no real secrecy, but keeping the key file out of the public
repo is why it lives in a secret rather than being committed.)

## Cause 4 — corrupt / truncated download on the device

A ~60 MB file pulled through a basic e-ink browser sometimes lands truncated, or
gets saved as `…apk.bin` / `…apk.1`. Symptoms are identical to a bad signature.
Rule it out by checking the size/hash on the device matches the release asset,
or sideload over USB / a USB stick instead of the on-device browser.

## Reference: the AINOTE 2

| | |
|---|---|
| OS | Android 14 (API 34), with Google Play |
| SoC | Rockchip RK3576 (arm64) |
| Needs v1 signature | **yes** |
| Known-good `targetSdk` | ≤ 34 |
