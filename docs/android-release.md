# Android APK release & the "invalid APK" problem on e-ink tablets

Locked-down e-ink firmwares (iFLYTEK AINOTE, some Onyx Boox, etc.) are much
pickier about APKs than a normal phone. When one of them refuses to install our
APK with *"invalid APK" / "package appears to be invalid" / "应用未安装"*, it is
almost always one of the causes below. This file is the checklist so we don't
re-diagnose it from scratch every time.

## TL;DR — what a valid APK for these devices needs

1. **A v1 (JAR) signature**, in addition to v2/v3. ← the original bug, now fixed
   in `android/app/build.gradle.kts` and guarded in CI.
2. A `targetSdkVersion` the firmware actually knows. Targeting an SDK *newer*
   than the device's Android version can trip an OEM installer's parser.
3. An ABI the device supports — we ship `arm64-v8a` + `armeabi-v7a` + `x86_64`,
   which covers every e-ink tablet we've seen.
4. To be downloaded **intact** onto the device (the most boring cause, and a
   real one for a ~60 MB file pulled through a cheap built-in browser).

## How to diagnose, fast

Download the *exact* asset the device gets and inspect it on a real machine —
don't trust "it built fine":

```bash
# grab the published asset
curl -sL -o einkreader.apk \
  "$(curl -sL https://api.github.com/repos/xdamman/einkreader/releases/latest \
     | grep browser_download_url | grep '\.apk' | head -1 | cut -d'"' -f4)"

# 1. signatures — v1 MUST be true
apksigner verify --verbose --min-sdk-version 24 einkreader.apk | grep "scheme"

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

## Cause 3 — corrupt / truncated download on the device

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
