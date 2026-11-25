/// The destinations shown in the "Sell it" hub, with an honest status
/// for each. A destination is only actionable when a real, official
/// route exists today:
///
/// - [SellDestinationKind.handoff] — no posting API exists, so Snap2Sell
///   packages the listing and hands it to the platform's own create
///   flow (Facebook Marketplace).
/// - [SellDestinationKind.catalog] — a real API exists for businesses
///   (Facebook Shop / Commerce Catalog); needs seller business setup.
/// - [SellDestinationKind.api] — a real API exists (eBay Sell API);
///   needs the seller's developer/account connection.
/// - [SellDestinationKind.coming] — no public listing API at all today;
///   shown greyed so the roadmap is visible without pretending.
enum SellDestinationKind { handoff, catalog, api, coming }

class SellDestination {
  const SellDestination({
    required this.name,
    required this.tagline,
    required this.kind,
    this.actionLabel,
    this.blockedReason,
  });

  final String name;
  final String tagline;
  final SellDestinationKind kind;

  /// Button label when the destination can be used right now.
  final String? actionLabel;

  /// Why the destination cannot be used yet, in plain language. Null
  /// when [actionLabel] is set.
  final String? blockedReason;

  bool get isActionable => actionLabel != null;

  static const facebookMarketplace = SellDestination(
    name: 'Facebook Marketplace',
    tagline: 'Where most local buyers are. Facebook does not offer an '
        'app posting API, so Snap2Sell packages your listing and opens '
        'the Marketplace create page — you paste and publish.',
    kind: SellDestinationKind.handoff,
    actionLabel: 'List on Facebook Marketplace',
  );

  static const facebookShop = SellDestination(
    name: 'Facebook Shop',
    tagline: 'For sellers with a Facebook Page and Shop: listings sync '
        'to your catalog through Meta\'s official Catalog API.',
    kind: SellDestinationKind.catalog,
    blockedReason: 'Needs a Facebook Page + Shop and a catalog '
        'connection (business setup by the seller).',
  );

  static const ebay = SellDestination(
    name: 'eBay',
    tagline: 'List through eBay\'s official Sell API once your eBay '
        'account is connected.',
    kind: SellDestinationKind.api,
    blockedReason: 'Needs an eBay developer keyset and your eBay '
        'account connection (one-time setup).',
  );

  static const offerUp = SellDestination(
    name: 'OfferUp',
    tagline: 'Local buying and selling app.',
    kind: SellDestinationKind.coming,
    blockedReason: 'Coming — OfferUp has no public listing API.',
  );

  static const mercari = SellDestination(
    name: 'Mercari',
    tagline: 'Marketplace for shipped second-hand goods.',
    kind: SellDestinationKind.coming,
    blockedReason: 'Coming — Mercari has no public listing API.',
  );

  static const poshmark = SellDestination(
    name: 'Poshmark',
    tagline: 'Fashion and home goods marketplace.',
    kind: SellDestinationKind.coming,
    blockedReason: 'Coming — Poshmark has no public listing API.',
  );

  /// Hub order: actionable first, then business/API routes, then the
  /// greyed "coming" entries.
  static const List<SellDestination> all = [
    facebookMarketplace,
    facebookShop,
    ebay,
    offerUp,
    mercari,
    poshmark,
  ];
}
