# eBay setup — what the owner must supply

Snap2Sell already builds complete eBay Sell Inventory API payloads
(`lib/services/ebay_listing_service.dart`, unit-tested). Nothing is
sent yet: eBay requires a registered developer keyset and each
seller's OAuth consent. This doc lists exactly what the owner must
provide before the eBay destination in the Sell hub can switch on.

## Owner steps

1. Join the eBay Developers Program: https://developer.ebay.com
   (free; sign in with the Zoom Industries eBay account).
2. Create an application keyset for "Snap2Sell" (production, not
   sandbox, when ready to go live). You will get:
   - **App ID (Client ID)**
   - **Cert ID (Client Secret)**
   - **Dev ID**
   Hand these to Jarvis via the secure vault — the Cert ID is a
   secret and must never be pasted into chat, code, or the app.
3. In the keyset's User Token settings, set the **RuName** (redirect
   URL name) — Jarvis will supply the exact redirect URL the backend
   uses for the OAuth consent flow.
4. Each seller (starting with Zoom's own account) completes eBay's
   OAuth consent once, granting the Sell API scopes:
   `https://api.ebay.com/oauth/api_scope/sell.inventory`,
   `.../sell.account`, `.../sell.fulfillment`.
   The backend stores the resulting refresh token per seller.

## What eBay needs that only a connected account can give

The offer payload marks these `CONFIG_REQUIRED` until a real account
is connected — they are per-account values, never invented:

- `fulfillmentPolicyId`, `paymentPolicyId`, `returnPolicyId`
  (read from the seller's account via the Sell Account API, or created
  once during onboarding)
- `merchantLocationKey` (the seller's inventory location)
- `categoryId` per item (resolved via the Taxonomy API from the
  listing title/category)

## Listing flow once connected (backend sends)

1. `PUT /sell/inventory/v1/inventory_item/{sku}` — inventory item
   (sku = `snap2sell-<item id>`, stable so re-syncs update in place).
2. `POST /sell/inventory/v1/offer` — fixed-price offer.
3. `POST /sell/inventory/v1/offer/{offerId}/publish` — goes live.
4. Marking a listing sold in the app → backend withdraws the offer /
   zeroes quantity.

Image URLs in the inventory item must be hosted (eBay EPS upload or
seller hosting) — same backend photo-hosting dependency as the
Facebook catalog route.
