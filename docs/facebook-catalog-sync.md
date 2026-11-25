# Facebook Commerce Catalog sync — spec

The business route for Facebook selling. A seller who runs a Facebook
**Page with a Shop** can push Snap2Sell listings into their Commerce
**Catalog** through Meta's official Catalog API. Items in the catalog
can then surface in the seller's Facebook Shop (and Instagram Shopping
where enabled).

This is NOT personal Marketplace posting. Meta has no API for that;
catalog items belong to the business, not the seller's personal
Marketplace profile. The app's hub UI states this plainly.

## Status in the app today

- `lib/services/facebook_catalog_service.dart` builds and unit-tests
  the exact request payloads (product fields, create + update
  requests). It makes **no network calls** — no Meta credentials exist
  in the app, by design.
- Sending plugs into the existing Cloud Function backend later: the
  backend holds the seller's access token in Secret Manager (same
  pattern as the Gemini key today) and forwards the pre-built request.

## How a seller connects (future backend flow)

1. Seller taps "Connect Facebook" in the Sell hub and completes
   Facebook Login (see facebook-app-setup.md).
2. Seller picks their Page; the backend looks up the Page's Commerce
   account and product catalog:
   - `GET /{page-id}?fields=commerce_merchant_settings` → merchant id
   - `GET /{commerce-merchant-id}/product_catalogs` → catalog id
3. Seller's user access token (with the permissions below) is stored
   server-side only. For unattended sync, the seller creates a
   **System User** in Business Settings and assigns it to the catalog;
   its token is what the backend stores.

## Required permissions

- `catalog_management` — create/update catalog items.
- `business_management` — read the business's Pages/catalogs.
- Both need Meta App Review + business verification (owner step).

## API calls the builder produces

Create item:

```
POST /{catalog-id}/products
{
  "retailer_id": "snap2sell_<item id>",     // stable per listing
  "title": "...",
  "description": "...",
  "availability": "in stock",
  "condition": "used_good",                  // mapped from Snap2Sell grade
  "price": "12.00 USD",                      // amount + ISO currency
  "image_url": "https://.../main.jpg",       // hosted URL, required
  "additional_image_urls": ["https://.../extra.jpg"],
  "brand": "Snap2Sell seller"
}
```

Update item (price/title/photo changes after an edit in the app):

```
POST /{catalog-item-id}   // Graph id returned at create time
{ ...same product fields... }
```

Condition mapping (Snap2Sell → Meta): Like New → `used_like_new`;
Excellent → `used_good`; Good → `used_good`; Fair → `used_fair`;
Poor → `used_fair`.

## Open items before this can send

- Hosted image URLs: the Catalog API cannot read local files. The
  backend must host listing photos (e.g. a storage bucket with signed
  or public URLs) and pass the URLs into the request builder.
- Token storage + refresh in the backend (Secret Manager), one token
  set per connected seller.
- Catalog-item Graph id returned at create time must be stored against
  the listing so updates hit the same item.
- Sold handling: set `availability` to `out of stock` on the update
  call when a listing is marked sold in the app.
