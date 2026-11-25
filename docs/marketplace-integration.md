# Marketplace integration — overview

Built 2026-11-25 on branch `marketplace-integration` (perfection loop
round 2). Everything here respects one verified constraint: **Meta has
no public API for posting consumer Facebook Marketplace listings, and
Facebook Login carries no Marketplace posting permission.** No
unofficial automation, no credential handling, no bot posting — ever.

## What shipped

### 1. "Sell it" hub (`lib/screens/sell_hub_screen.dart`)
Reached from the Price & Platforms screen. Lists every destination
with an honest status chip:

| Destination | Route | Status |
|---|---|---|
| Facebook Marketplace | Handoff | Actionable now |
| Facebook Shop | Catalog API (business) | Blocked: seller Page/Shop setup |
| eBay | Sell Inventory API | Blocked: developer keyset + account |
| OfferUp / Mercari / Poshmark | None exists | Greyed "coming" |

The existing share-sheet flow on the platforms screen is untouched.

### 2. Facebook connection (`lib/services/facebook_auth_service.dart`)
`FacebookAuthService` interface + `ConfigGatedFacebookAuthService`.
The Meta app id comes from the `FACEBOOK_APP_ID` dart-define
(`lib/services/config.dart`), empty by default = CONFIG REQUIRED.
With no app id the hub shows "Not set up yet" and Connect explains
the owner setup — it never fakes a connection. Owner steps:
facebook-app-setup.md.

### 3. One-tap Marketplace handoff (`lib/services/marketplace_handoff.dart`)
One button: copies the pre-formatted listing text (title, price,
condition, description) → shares all listing photos via the OS share
sheet → deep-links to facebook.com/marketplace/create/item.

**DESIGNED tap count** (designed, not yet measured on a device):
- In Snap2Sell + share sheet: **2 taps** (the button; one share-sheet
  target/dismiss).
- Inside Facebook: photo field (1) + select photos (1 per photo),
  paste into title and description (long-press + Paste = 2 per
  field), price entry (1–2), Publish (1).
- **Total ≈ 8–10 taps** end to end. On-device measurement is still
  pending and must replace this estimate before any "one-tap"
  language is used with users.

### 4. Commerce Catalog sync (`lib/services/facebook_catalog_service.dart`)
Client-side request builder for the Catalog API (create + update
product items), with permissions `catalog_management` +
`business_management`. No live calls; sending plugs into the Cloud
Function backend later. Spec: facebook-catalog-sync.md.

### 5. eBay (`lib/services/ebay_listing_service.dart`)
Sell Inventory API payload builders (inventory item + offer) behind
the same `ListingPayloadBuilder` interface. Account-specific values
are emitted as `CONFIG_REQUIRED` placeholders. Owner steps:
ebay-setup.md.

### 6. Marketplace Partnership Program
Eligibility note: marketplace-partnership-eligibility.md (research
only — nothing applied for).

## Live vs config-blocked

- **Live today:** Sell hub, Marketplace handoff, all payload builders
  (unit-tested), honest blocked states.
- **Config-blocked:** Facebook Login (needs Meta app id + SDK wiring),
  Catalog sends (needs seller Page/Shop, tokens, hosted photo URLs,
  backend sender), eBay sends (needs keyset, OAuth, policy/location
  ids, hosted photo URLs).
