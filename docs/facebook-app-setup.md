# Facebook app setup — owner steps (one-time)

Snap2Sell's Facebook connection is built and shipped in an honest
"not configured" state. It switches on only after the app owner
registers Snap2Sell as a Meta app and supplies the app id. Nothing in
the app fakes a connection before this is done.

Important, verified constraint: Facebook Login has **no** Marketplace
posting permission, and Meta offers **no** public API for posting
consumer (personal) Marketplace listings. The Facebook connection is
used for (1) seller identity and (2) the business route — Page/Shop
catalog sync (see facebook-catalog-sync.md). Personal Marketplace
posting stays a handoff (the app packages the listing and opens
Facebook's own create page) no matter what is configured here.

## Owner steps

1. Go to https://developers.facebook.com and sign in with the Facebook
   account that should own Snap2Sell's developer assets.
2. My Apps → Create App. Choose type **Consumer** (or "Other" →
   Consumer) and name it `Snap2Sell`. Use the Zoom Industries business
   account if Meta asks for one.
3. In the app dashboard, add the **Facebook Login** product.
4. Facebook Login → Settings: add the Android and iOS redirect /
   OAuth settings the dashboard asks for. For Android you will need
   the app's package name (`ca.zoomindustries.snap2sell`) and the
   key hash of the release signing key — Meta's dashboard shows where
   each goes.
5. Copy the **App ID** from Settings → Basic.
6. Hand the App ID to Jarvis (it is not a secret — it ships inside the
   app). Jarvis will:
   - set the `FACEBOOK_APP_ID` dart-define in CI,
   - add the official `flutter_facebook_auth` package and replace
     `ConfigGatedFacebookAuthService` with the SDK-backed
     implementation of the same `FacebookAuthService` interface,
   - add the AndroidManifest / Info.plist entries the SDK requires,
   - verify login on a real device.
7. If the Shop/catalog route will be used, also complete Meta's
   **App Review** for the `catalog_management` and
   `business_management` permissions (business verification of Zoom
   Industries is required by Meta for these).

## What works before this setup

- The "Sell it" hub shows Facebook as "Not set up yet" with this
  explanation — never as connected.
- The Facebook Marketplace handoff (copy → share photos → open create
  page) works fully with no login at all.
