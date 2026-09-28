/// The build flavor, set automatically by `flutter build --flavor <name>`
/// (empty for a plain build). See android/app/build.gradle.kts.
const String appFlavor = String.fromEnvironment('FLUTTER_APP_FLAVOR');

/// In-app APK self-update (download + launch the system installer) ships only
/// in sideload builds. The Play Store build (`--flavor play`) omits it — and
/// the REQUEST_INSTALL_PACKAGES permission it needs — because the store handles
/// updates and would reject that permission.
const bool kSelfUpdateSupported = appFlavor != 'play';

/// Choosing a custom archive folder (e.g. one synced by Syncthing) needs the
/// MANAGE_EXTERNAL_STORAGE ("All files access") permission on Android 11+,
/// which the Play Store rejects for apps that aren't file managers — so the
/// option ships only in sideload builds, like self-update.
const bool kCustomStorageSupported = appFlavor != 'play';

/// The project's own X (Twitter) OAuth 2.0 Client ID, baked into Play Store
/// builds (`--dart-define=TWITTER_CLIENT_ID=…`, from a CI secret) so people
/// just tap "Connect" instead of creating a developer app. Empty in other
/// builds, which keep the bring-your-own Client ID field. It's a public
/// PKCE client id, not a secret — but every connected user's API usage is
/// billed to the project's X developer account.
const String kBuiltInTwitterClientId =
    String.fromEnvironment('TWITTER_CLIENT_ID');
