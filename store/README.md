# Publishing einkreader to Google Play

Everything in this folder is generated or paste-ready. The one thing that
must happen in a browser is the Play Console itself (developer account,
one-time $25).

## Assets in this folder

| File | Use in Play Console |
| --- | --- |
| `icon_512.png` | App icon (512×512) |
| `feature_graphic.png` | Feature graphic (1024×500) |
| `screenshots/phone/*.png` | Phone screenshots (1170×2532) |
| `screenshots/tablet/*.png` | 7"/10" tablet screenshots (1200×1600) |
| `listing.md` | Title, descriptions, data safety, rating answers |
| `../site/public/demo.mp4` | Optional promo video (upload to YouTube, link it) |

Regenerate assets after UI changes:

    flutter test test/screenshots/screenshot_test.dart test/screenshots/store_assets_test.dart \
      --update-goldens --dart-define=screenshots=true
    tool/make_demo_video.sh   # rebuilds site/public/demo.mp4

## One-time setup (you)

1. Play Console → create developer account (personal, $25 once).
2. Create app: "einkreader", App, Free, category News & Magazines.
3. Store listing: paste from `listing.md`, upload assets above.
4. Privacy policy URL: https://einkreader.app/privacy.html
5. Data safety + content rating: answers drafted in `listing.md`.

## Build & upload (per release)

Play requires an **App Bundle (.aab)**, not the APK we ship on GitHub.
Same code, same keystore:

    flutter build appbundle --release
    # → build/app/outputs/bundle/release/app-release.aab

Upload to Production (or start with Internal testing). On first upload,
enroll in **Play App Signing** (Google re-signs for devices; our keystore
becomes the upload key — keep it safe either way).

Note: Play review typically takes a few days for a first release. The
GitHub APK channel keeps working unchanged; in-app self-update should be
disabled in a later Play-specific build variant (Play policy discourages
self-updating apps) — flagged as a TODO before wide Play rollout.

## After approval

- Add the Play link to einkreader.app next to the APK button.
- Plugin subscriptions: create the subscription (10/mo, 50/yr base plans)
  and the 100/5yr one-time product under Monetize; then we wire Play
  Billing + server verification and retire free early access.
