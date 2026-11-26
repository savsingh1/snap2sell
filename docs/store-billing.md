# Store Billing (Google Play now, Apple later)

Snap2Sell has store-billing **plumbing** built in, but it is **switched
off**. No paid tier exists yet: no prices, no product shape, and no
feature gates have been decided, and nothing in the app is locked
behind a purchase. This document is the owner's checklist for turning
it on later, plus a record of the decisions that are still open.

## How it works today

- Code: `lib/services/billing_config.dart` (config parsing),
  `lib/services/billing_service.dart` (the billing layer + seams),
  `lib/services/in_app_purchase_gateway.dart` (the only file that
  talks to the `in_app_purchase` plugin), `lib/screens/premium_screen.dart`
  (the paywall surface), wired into `AppState`
  (`lib/providers/app_state.dart`).
- With no build-time configuration (the default), billing is fully
  inert:
  - `BillingService.initialise()` settles into a `notConfigured` state
    **without touching the store** — no store queries, and the real
    store gateway is never even constructed (it sits behind
    `LazyBillingGateway`, because the plugin starts a store connection
    when its instance is created).
  - No purchase UI exists anywhere: the Profile screen's **Premium**
    tile renders only when billing is configured.
  - The app behaves exactly as the free app.
- When configured, the premium screen lists the products **the store
  returns** for the configured ids — titles, descriptions, and prices
  all come from the store listing, never from the app. Purchases,
  pending states, errors, cancellation, and restore are handled by
  `BillingService`; the entitlement state lives on `AppState`
  (`billingConfigured`, `hasPremiumEntitlement`, `billing`).

## Configuring product ids

Product ids are injected at build time — they are never hardcoded:

```sh
flutter run \
  --dart-define=SNAP2SELL_PRODUCT_IDS=PRODUCT_ID_1:subscription,PRODUCT_ID_2:nonConsumable \
  --dart-define=AI_BACKEND_URL=... (etc.)
```

Format: comma-separated entries, each `productId` or `productId:kind`,
where `kind` is one of:

| Kind            | Meaning                                             |
| --------------- | --------------------------------------------------- |
| `subscription`  | Recurring subscription; owned while active.         |
| `nonConsumable` | One-time purchase; owned forever. (Default if the kind is omitted.) |
| `consumable`    | Bought, consumed, buyable again.                    |

Parsing rules (see `parseBillingProductIds` in
`lib/services/billing_config.dart`): whitespace is ignored, empty
entries are skipped, duplicate ids keep the first occurrence, and an
unrecognised kind falls back to `nonConsumable`.

The ids in the dart-define must match the ids created in the store
console **exactly**. Ids the store does not know are reported on the
premium screen as products that could not be loaded — they are never
silently treated as purchasable.

## What must be created in Play Console first

Before a configured build can sell anything, the owner must, in the
Google Play Console for Snap2Sell:

1. **One-time products** (Monetize → Products → One-time products) for
   every `nonConsumable` and `consumable` id: create the product id,
   set its price, and activate it.
2. **Subscriptions** (Monetize → Products → Subscriptions) for every
   `subscription` id: create the subscription id, add at least one
   base plan (billing period, price, renewal), and activate both.
3. **A build uploaded** to at least an internal testing track — store
   products only resolve for builds from Play tracks, not sideloaded
   APKs.
4. **License testers** (Settings → License testing): add the Google
   accounts that will test purchases so test buys are free and
   refundable during development.

The same ids must later be mirrored in App Store Connect (in-app
purchases / auto-renewable subscriptions) before an iOS build is
configured with them; the app-side code is shared, only the console
setup is per-store.

## Owner decisions still needed (NOT decided — do not guess)

1. **Price(s).** What does the paid tier cost, in which currency
   anchor? Prices live in the store consoles, not the app, but the
   owner must choose them.
2. **Product shape.** Subscription, one-time, or both? Consumables at
   all? This decides which product kinds get created and configured.
3. **What the paid tier unlocks.** No feature is gated today. The
   owner must decide what (if anything) a purchase unlocks before any
   gate is written — and any gate must use
   `BillingService.hasVerifiedEntitlement`, never the client-side
   ownership record (see below).
4. **Verification backend.** Whether/when to build the receipt
   verification endpoint described below. A real paid tier should not
   ship without it.
5. **Apple timing.** When to mirror the products in App Store Connect.

## Receipt verification — the seam, and its current honest state

Client-side purchase records are **not proof of payment** (stores can
be spoofed on rooted/jailbroken devices). The billing layer therefore
separates *owning* from *verified*:

- `PurchaseVerifier` (`lib/services/billing_service.dart`) is the
  interface a verification backend plugs into: it receives the
  purchase plus its store verification token (`StorePurchase
  .verificationData`) and answers verified / unverified.
- The shipped implementation, `UnverifiedPurchaseVerifier`, **verifies
  nothing**. Purchases are recorded as owned on the device
  (`AppState.hasPremiumEntitlement`), the premium screen says plainly
  that the purchase "is not treated as confirmed", and
  `BillingService.hasVerifiedEntitlement` stays `false`.
- `completePurchase` (Play acknowledgement) still runs for delivered
  purchases so the store stops re-delivering them and does not
  auto-refund for non-acknowledgement. Acknowledgement is store
  bookkeeping — it is **not** verification, and the code says so at
  the call site.

To make verification real, a future backend step must:

1. Add a Snap2Sell backend endpoint that accepts the store token.
2. Validate it server-side: Google Play Developer API
   (`purchases.products` / `purchases.subscriptionsv2`) for Android,
   Apple App Store Server API for iOS.
3. Implement `PurchaseVerifier` to call that endpoint and return
   `PurchaseVerification.verified()` only on the server's say-so.
4. Only then gate any paid feature — on `hasVerifiedEntitlement`.

## Testing the plumbing

- Unit tests (`test/billing_service_test.dart`) run entirely against a
  fake gateway: config parsing, the gateway-never-touched
  not-configured state, the purchase lifecycle (pending → purchased /
  error / canceled, restore), and the verifier seam. No real store
  calls in tests, ever.
- The premium screen has a golden (`test/goldens/premium.png`) rendered
  against a fake store gateway.
- End-to-end store testing requires the Play Console steps above plus
  a license-tester account and a build that carries the real
  `SNAP2SELL_PRODUCT_IDS` dart-define.
