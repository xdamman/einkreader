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

    buildTypes {
        release {
            // Use the stable release key (from android/key.properties) when present,
            // otherwise the debug key so `flutter run --release` works locally.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
