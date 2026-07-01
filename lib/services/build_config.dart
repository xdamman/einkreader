/// The build flavor, set automatically by `flutter build --flavor <name>`
/// (empty for a plain build). See android/app/build.gradle.kts.
const String appFlavor = String.fromEnvironment('FLUTTER_APP_FLAVOR');

/// In-app APK self-update (download + launch the system installer) ships only
/// in sideload builds. The Play Store build (`--flavor play`) omits it — and
/// the REQUEST_INSTALL_PACKAGES permission it needs — because the store handles
/// updates and would reject that permission.
const bool kSelfUpdateSupported = appFlavor != 'play';
