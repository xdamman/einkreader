# Publishing einkreader on Google Play

Everything here is generated or paste-ready. What only you can do happens
in the Play Console and in two GitHub secrets.

## At a glance

| Thing | Value |
| --- | --- |
| Package name | `com.xlcollective.einkreader` (the `play` build flavor) |
| What to upload | `einkreader-vX.Y.Z-play.aab`, attached to every GitHub release |
| Target API | 36 (Android 16) — required since Aug 31, 2026 |
| Privacy policy | https://einkreader.app/privacy.html |
| Delete-account URL | https://einkreader.app/delete-account |
| Listing, data safety, rating | `listing.md` |
| Icon, feature graphic, screenshots | this folder (`python3 tool/store_assets.py` refreshes them) |

The sideloaded APK on GitHub (`com.xdamman.einkreader`) is unchanged and
keeps self-updating. The Play app is a separate app: both can be
installed side by side (each with its own library).

## 1. One-time GitHub setup

1. **X client id for Play users** (so they just tap "Connect"):
   `gh secret set TWITTER_CLIENT_ID` and paste the OAuth 2.0 Client ID
   of the project's X developer app (Settings → the one you use today).
   It's a public id, not a secret — but every Play user's X API usage is
   billed to that developer account (X bills per post read).
2. Nothing else: the existing `ANDROID_KEYSTORE_*` secrets sign the
   bundle; Play uses that key as the **upload key**.

## 2. One-time Play Console setup

1. App: einkreader · App · Free · category News & Magazines.
2. **Store listing**: paste from `listing.md`; upload `icon_512.png`,
   `feature_graphic.png`, `screenshots/phone/*` and `screenshots/tablet/*`.
3. **App content**: privacy policy URL; data safety (table in
   `listing.md`); content rating (Everyone); target audience 18+ (or
   13+); no ads; news app declaration: No; account deletion URL.
4. **Play App Signing**: accept Google-managed signing on first upload.
5. **Personal developer account?** New personal accounts must run a
   **closed test with at least 12 testers for 14 days** before
   Production is unlocked. Create a Closed testing track, add testers
   (Google Group or emails), upload the bundle there first.

## 3. Every release

1. Tag as usual (`git tag vX.Y.Z && git push origin vX.Y.Z`).
2. When the GitHub release is built, download
   `einkreader-vX.Y.Z-play.aab` from it.
3. Play Console → the track → Create release → upload the `.aab` → paste
   release notes (template in `listing.md`) → review → roll out.

versionCode comes from `pubspec.yaml` (`+N`), so every tag gets a new,
higher code automatically.

## Differences in the Play build

- No in-app self-update (Play updates the app) and no
  REQUEST_INSTALL_PACKAGES permission.
- No custom archive folder (needs "All files access", which Play
  rejects): the library lives in app storage.
- X sign-in uses the project's client id instead of asking for one.

CI fails the release if either forbidden permission ever appears in the
Play bundle, or if its package name isn't `com.xlcollective.einkreader`.
