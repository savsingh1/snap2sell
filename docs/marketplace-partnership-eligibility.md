# Marketplace Partnership Program — eligibility note for Snap2Sell

Researched 2026-11-25 (web sources, Meta's own announcement fetched in
full; Meta's partner/help pages would not load directly, so their
wording is taken from verbatim quotes in secondary coverage — noted
per claim). **Research only — nothing applied for, nobody contacted.**

## Verdict up front

**Snap2Sell does not qualify today, and Canada is out of scope
entirely.** The program is a narrow, EEA-only compliance program Meta
created after an EU antitrust fine, for established rival classified
platforms to syndicate their existing consumer-to-consumer (C2C)
listings into Marketplace. It is not a general developer program, and
it is not a posting API for an app's users.

## Who qualifies

Per Meta's Feb 13, 2025 announcement (updated May 22, 2025), eligible
partners are "online classified ad service providers as defined in the
European Commission's decision" distributing C2C listings to users in
the European Economic Area:
https://about.fb.com/news/2024/11/our-response-to-the-european-commissions-decision-on-facebook-marketplace/

Meta's eligibility criteria (Business Help, quoted in
https://www.valueaddedresource.net/meta-expands-eu-facebook-marketplace-partnership/):

1. Sellers list, buyers review, listings for **pre-owned products**
2. Listings **searchable and filterable by category**
3. Buyers can **contact sellers to negotiate**
4. A **majority of transactions complete without the service's
   intervention** (e.g. offline)
5. **Majority consumer (non-business) inventory**

Named partners to date are all national-scale incumbents: eBay
(initial test), Catawiki (Netherlands), Vendora (Greece), Tradera
(Sweden) and Jófogás (Hungary) announced.

## Geographic focus

**EEA only.** The partner must have C2C listings *in an EEA country*,
shown to EEA users who opt in; purchases complete on the partner's
own website. The only non-EEA data point is a Jan 2025 single-partner
test with eBay that included the US — a named pilot, not an open
program. **No Canadian program, test, or eligibility path exists** in
any Meta source found.

## Concrete requirements

- **Volume:** no published minimum volume, user, or revenue threshold.
  Meta screens case-by-case after an interest form: "we determine your
  eligibility", then details (including CPC pricing) are shared.
- **Approval:** interest form → Meta eligibility determination →
  onboarding with a Meta support team under a Business Manager account.
- **Technical:** listings ingested/updated through Meta's own API;
  listing data (description, seller name, delivery type) supplied;
  sold/unavailable items must be removed promptly.
- **Compliance:** only consumer-seller listings may be sent (partner
  must distinguish consumers from traders); prohibited-item screening
  per Meta Commerce Policies; partner is liable for its listings.
- **Commercial:** initial fee-free period, then **cost-per-click** on
  click-throughs from Marketplace to the partner's site.
- **Presentation:** partner listings appear in Marketplace feed/search,
  "ranked neutrally", badged with a partner icon; EEA users choose
  which partners they see.

## Why Snap2Sell is out — three independent blockers

1. **Geography (hard):** Zoom Industries is in British Columbia,
   Canada, with Canadian listings/users. The program requires EEA
   listings for EEA users. No Canadian path exists.
2. **Stage/inventory (hard):** eligibility requires an *operating*
   classified service with live majority-consumer pre-owned inventory.
   A pre-launch app has nothing to syndicate.
3. **Model fit (probable):** the program syndicates a platform's
   listings *out* to Marketplace with the transaction finishing on the
   partner's site. It is not a way for Snap2Sell users to post *to*
   Marketplace under their own Facebook accounts — that capability
   does not exist publicly at any scale.

## What it would take

1. Launch Snap2Sell as a real classified service **in an EEA country**
   with live C2C pre-owned listings meeting all five criteria.
2. Build a majority-consumer seller base, consumer-vs-trader
   separation, prohibited-item screening, and sold-item removal.
3. Reach credible operating scale (Meta decides; every approved
   partner so far is a national-scale incumbent).
4. Submit the interest form, pass Meta's determination, integrate
   with Meta's ingestion API, accept CPC pricing.

## Practical implication for Snap2Sell

Do not plan on programmatic Facebook Marketplace posting for the
Canadian launch. The real routes remain: (a) the one-tap handoff
built in this integration (seller finishes in Facebook's own create
flow), and (b) Commerce Catalog sync for business sellers. Revisit
the Partnership Program only if Snap2Sell ever launches a substantial
EEA classified operation.

*Related but different, for the record: Meta's historic invite-only
vertical syndication (autos, rentals, jobs) wound down years ago —
partner vehicle listings ended 2021, business-Page vehicle/real-estate
listings ended Jan 30, 2023 — and has no open application today.*
