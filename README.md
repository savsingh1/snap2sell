# Snap2Sell

**Snap it. Sell it. Done.** — an AI-powered resale listing app for iOS and Android, built with Flutter (one codebase).

Snap a photo of any household item → AI identifies it, grades the condition, suggests a resale price, and writes the listing → cross-post to marketplaces from the share sheet.

## Features (MVP)

- **Welcome / Capture** — big "Take a Photo" button, "Upload from Gallery", photo tips.
- **Home dashboard** — "Snap an Item" CTA, estimated inventory value, recent items (thumbnail, condition, price, status).
- **AI Analysis** — animated pipeline: identifying → condition → market prices → writing the listing.
- **Results & Listing editor** — editable title, category, condition chips, suggested price + range, editable description, "Copy Listing".
- **Price & Platforms** — toggles for Facebook Marketplace, eBay, Craigslist, OfferUp; per-platform copy buttons; "Open sell page" links; **Post Listing** opens the system share sheet pre-filled with listing text + photo.
- **Confirmation** — "Listing Draft Ready!" with Copy to Clipboard / Save for Later / Start Another.
- **Profile** — stats, Payment Methods, Past Listings, Help & Support.
- **Local-first storage** — listings persist on-device (shared_preferences + app documents); Firebase-ready abstraction for later.

## Project structure

```
snap2sell-app/
├── lib/
│   ├── main.dart                  # app entry, provider wiring, navigator key
│   ├── app_theme.dart             # brand palette (purple #5E00D6, mint #4ADE80), SnapLogo
│   ├── models/
│   │   ├── item.dart              # Item + ItemCondition + ListingStatus (JSON-ready)
│   │   └── ai_analysis_result.dart
│   ├── services/
│   │   ├── config.dart            # --dart-define keys (never hardcoded)
│   │   ├── ai_service.dart        # AiService interface, MockAiService (default),
│   │   │                          # OpenAiVisionService (live, key-gated)
│   │   ├── listing_service.dart   # listing text builder, clipboard, share sheet
│   │   └── storage_service.dart   # StorageService interface + LocalStorageService
│   ├── providers/
│   │   └── app_state.dart         # ChangeNotifier: items, AI pipeline, platforms
│   ├── screens/
│   │   ├── welcome_screen.dart
│   │   ├── main_scaffold.dart     # Home | Snap FAB | Profile tabs
│   │   ├── home_screen.dart
│   │   ├── processing_screen.dart
│   │   ├── results_screen.dart
│   │   ├── platforms_screen.dart
│   │   ├── confirmation_screen.dart
│   │   └── profile_screen.dart
│   └── widgets/
│       ├── capture_helpers.dart   # camera/gallery sheet, flow navigation
│       └── item_card.dart         # recent-item row
├── android/  ios/                 # platform scaffolding (see "Platform folders" below)
├── test/item_test.dart            # model + listing-text unit tests
├── .env.example                   # documented build-time variables
└── FIREBASE_SETUP.md              # how to add Firebase later
```

## Prerequisites

- Flutter SDK 3.22+ (`flutter doctor` clean, with Android Studio / Xcode for device builds)
- A physical device or emulator (camera needs a real device for full testing)

## Run it

```bash
cd snap2sell-app
flutter pub get

# Demo mode (default): mock AI, zero keys, zero cost
flutter run

# Live AI mode: pass your vision API key at build time
flutter run --dart-define=OPENAI_API_KEY=sk-your-key-here
# optional: --dart-define=OPENAI_MODEL=gpt-4o-mini
```

Without a key the app uses `MockAiService`, which returns realistic demo listings
for common household items — the entire flow works offline, which is also ideal
for store screenshots and investor demos. If the live key fails at runtime
(bad key, no network, unparsable response), the app falls back to the mock
rather than crashing.

## Tests & analysis

```bash
flutter test            # unit tests (models, listing text)
flutter analyze         # lints (flutter_lints)
```

## Build release artifacts

```bash
# Android APK (sideload / internal testing)
flutter build apk --release

# Android App Bundle (Google Play upload)
flutter build appbundle --release

# iOS (on macOS with Xcode; then archive via Xcode for App Store)
flutter build ipa --release
```

## Marketplace integrations

**Honest mechanics — read before promising "one-tap posting":**

| Marketplace | Public listing API? | MVP mechanism |
|---|---|---|
| Facebook Marketplace | **No** — no public API, and scraping/automation violates their ToS | Share sheet + clipboard + sell-page link |
| OfferUp | **No** public listing API | Share sheet + clipboard + sell-page link |
| Craigslist | No API (post via web form) | Share sheet + clipboard + post.craigslist.org link |
| eBay | **Yes** — Sell API exists (needs developer account + OAuth) | MVP uses the same share-sheet flow; API posting is a v1.1 roadmap item |

"Post Listing" therefore opens the **system share sheet** with the photo and
formatted listing text, and each platform row has its own **copy button** plus
an **open-sell-page** button (`url_launcher`, best-effort URLs). The user
finishes the post inside each marketplace app — this is the only App-Store-safe
approach without private APIs.

Roadmap: eBay Sell API integration (OAuth via `flutter_web_auth_2`),
saved per-platform defaults, listing performance tracking.

## Firebase (later)

The persistence layer is behind the narrow `StorageService` interface
(`loadItems` / `saveItems`), so swapping in Firestore is a single-class change.
Full steps are in [FIREBASE_SETUP.md](FIREBASE_SETUP.md). Not wired in the MVP —
no Firebase project, no google-services files, no keys in this repo.

## Store-submission checklist

- **Bundle IDs:** `ca.zoomindustries.snap2sell` (Android `applicationId` and iOS
  `CFBundleIdentifier` are already set in the platform placeholders).
- **Accounts (owner to complete, NOT done):**
  - [ ] Apple Developer Program enrollment ($99 USD/yr) with
        `zoomindustriesltd@gmail.com` as the account email.
  - [ ] Google Play developer account ($25 USD one-time) with
        `zoomindustriesltd@gmail.com`.
  - [ ] Create the App Store + Play listings for `ca.zoomindustries.snap2sell`.
- **Before first upload:**
  - [ ] Generate full platform folders on a Flutter machine:
        `flutter create --org ca.zoomindustries --project-name snap2sell --platforms android,ios .`
        then copy `lib/`, `pubspec.yaml`, `test/` over it (the `android/` and
        `ios/` folders in this repo are minimal placeholders with the correct
        IDs, permissions, and usage descriptions).
  - [ ] App icons: `flutter_launcher_icons` (add your camera+price-tag logo).
  - [ ] Splash: `flutter_native_splash` (purple background, white logo).
  - [ ] Sign the Android release (upload key) and configure iOS signing team.
  - [ ] Privacy policy URL + data-safety form (photos stay on-device in MVP).
  - [ ] Replace the "Guest Seller" profile with real auth (see FIREBASE_SETUP.md).
- **Config:** live AI key is injected via `--dart-define=OPENAI_API_KEY=...`
  at release build time — never commit a key.

## Known MVP limitations

- Photos are copied to app documents; very large libraries could grow storage —
  a future pass should downscale/compress on import.
- No user accounts yet — one device, one library (Firebase auth is the path).
- eBay one-tap posting not implemented (needs Sell API OAuth app approval).
- "Open sell page" links are best-effort web URLs; marketplaces change them.

## License

Proprietary — Zoom Industries Ltd. All rights reserved.
