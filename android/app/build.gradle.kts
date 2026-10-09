import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load a committed-key-free release signing config from android/key.properties if
// present. CI writes this file from GitHub secrets; locally it's absent, so the
// build falls back to the debug keystore (~/.android/debug.keystore). Because CI's
// secret holds that SAME debug keystore, local and CI builds share one signing
// identity — releases install/upgrade cleanly instead of being rejected as
// "invalid" for a key mismatch. See docs/android-release.md.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) load(FileInputStream(keystorePropertiesFile))
}

// The Google Play upload key, from android/play-key.properties (written by CI
// from the PLAY_* secrets). Play refuses bundles signed with a debug
// certificate, and the sideload key above IS a debug keystore — so the `play`
// flavor signs with its own upload key. (Play App Signing re-signs what
// reaches devices; this key only proves uploads come from us.)
val playKeystorePropertiesFile = rootProject.file("play-key.properties")
val playKeystoreProperties = Properties().apply {
    if (playKeystorePropertiesFile.exists()) {
        load(FileInputStream(playKeystorePropertiesFile))
    }
}

android {
    namespace = "com.xdamman.einkreader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    // Some locked-down e-ink installers (iFLYTEK AINOTE) reject the modern
    // uncompressed/page-aligned native-lib layout as "package appears to be
    // invalid". Force the legacy layout: compressed .so + extractNativeLibs=true.
    // This was THE fix for the AINOTE 2 install failure. See docs/android-release.md.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.xdamman.einkreader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // Pin the target to Android 14 (API 34) instead of Flutter's bleeding-edge
        // default (API 36 / Android 16). Locked-down e-ink firmwares (iFLYTEK
        // AINOTE 2 runs Android 14) can reject an APK that targets an SDK newer
        // than the device as "invalid". See docs/android-release.md.
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        getByName("debug") {
            // Force the legacy v1 (JAR) signature on in addition to v2/v3. AGP
            // drops v1 by default when minSdk >= 24, but some locked-down e-ink
            // firmwares (e.g. iFLYTEK) reject v2/v3-only APKs as "invalid".
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
        if (playKeystorePropertiesFile.exists()) {
            create("play") {
                storeFile = file(playKeystoreProperties["storeFile"] as String)
                storePassword = playKeystoreProperties["storePassword"] as String
                keyAlias = playKeystoreProperties["keyAlias"] as String
                keyPassword = playKeystoreProperties["keyPassword"] as String
            }
        }
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    // Signing is chosen per flavor (below), not per build type: a build
    // type's signing config would override the flavor's, and the `play`
    // flavor must never ship with the sideload (debug) key.
    buildTypes {
        release {
            signingConfig = null
        }
    }

    // Distribution channels. The `github` (sideload) flavor keeps the
    // original app id so existing installs keep self-updating; `play` is a
    // separate app on the Play Store (com.xlcollective.einkreader, set in the
    // Play Console — permanent once the first bundle is uploaded). The
    // `github` (sideload) flavor adds the
    // REQUEST_INSTALL_PACKAGES permission via src/github/AndroidManifest.xml;
    // `play` omits it so a Play Store build stays clean. Build with
    // `flutter build apk --flavor github` (or `--flavor play`). The flavor name
    // is exposed to Dart as FLUTTER_APP_FLAVOR (see build_config.dart).
    flavorDimensions += "distribution"
    productFlavors {
        create("github") {
            dimension = "distribution"
            // The stable sideload key (android/key.properties) when present,
            // otherwise the local debug key so `flutter run --release` works.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
        create("play") {
            dimension = "distribution"
            applicationId = "com.xlcollective.einkreader"
            // Play requires new apps and updates to target API 36 (Android
            // 16) since Aug 31, 2026. The sideload build stays on 34 for the
            // e-ink firmwares that reject newer targets (see defaultConfig).
            targetSdk = 36
            // The Play upload key when present (CI); locally falls back to
            // the debug key — fine for testing, rejected by Play (and CI
            // fails a release bundle signed that way).
            signingConfig = if (playKeystorePropertiesFile.exists())
                signingConfigs.getByName("play")
            else
                signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
