library;

/// Normalized vehicle-valuation models (Valuation Phase 0), mirroring the
/// real-estate module's honesty contract: a null field means "unknown /
/// unavailable". We NEVER write a zero, an invented number, or a guessed
/// string in place of real data.
///
/// Identifiers (VIN, mileage, condition) are user-supplied and confirmed —
/// never guessed from a photo (design §2.1).

/// A vehicle's normalized identity, from a VIN decode or from the
/// user-confirmed year/make/model/trim.
class VehicleIdentity {
  const VehicleIdentity({
    this.year,
    this.make,
    this.model,
    this.trim,
    this.bodyStyle,
    this.engine,
    this.drivetrain,
    this.sourceLabel = 'User-confirmed',
  });

  final int? year;
  final String? make;
  final String? model;
  final String? trim;
  final String? bodyStyle;
  final String? engine;
  final String? drivetrain;

  /// Where this identity came from (e.g. 'NHTSA vPIC', 'User-confirmed').
  final String sourceLabel;

  /// "2019 Honda Civic LX" — only the parts that are actually known.
  String get displayName => [
        if (year != null) '$year',
        if (make != null && make!.isNotEmpty) make,
        if (model != null && model!.isNotEmpty) model,
        if (trim != null && trim!.isNotEmpty) trim,
      ].join(' ');
}

/// Everything a value/comps lookup needs: identity plus the value drivers
/// a photo cannot show (mileage, condition, market location).
class VehicleQuery {
  const VehicleQuery({
    required this.identity,
    this.mileageKm,
    this.condition,
    this.postalCode,
  });

  final VehicleIdentity identity;

  /// User-entered odometer reading in kilometres. Never photo-guessed.
  final int? mileageKm;

  /// User-selected condition label (e.g. 'good').
  final String? condition;

  /// Market location for comparables (postal code or FSA).
  final String? postalCode;
}

/// Guide values from a licensed guide source (Canadian Black Book /
/// CARFAX Canada — design §2.2). Any field may be null when the source
/// does not publish that value class; null is never shown as zero.
class GuideValue {
  const GuideValue({
    this.wholesale,
    this.tradeIn,
    this.retail,
    this.privateParty,
    this.currency = 'CAD',
    this.asOf,
    required this.sourceLabel,
  });

  final double? wholesale;
  final double? tradeIn;
  final double? retail;
  final double? privateParty;
  final String currency;

  /// When the source's values were current.
  final DateTime? asOf;

  /// The guide that produced these values, labelled in the report
  /// (e.g. 'Canadian Black Book'). Never labelled "KBB" in Canada —
  /// KBB has no Canadian product (design §2.2).
  final String sourceLabel;
}

enum VehicleSellerType { dealer, private, unknown }

/// One live asking-price comparable from a listings source.
class VehicleComp {
  const VehicleComp({
    this.askingPrice,
    this.mileageKm,
    this.region,
    this.daysOnMarket,
    this.sellerType = VehicleSellerType.unknown,
    this.listingUrl,
    required this.sourceLabel,
  });

  final double? askingPrice;
  final int? mileageKm;

  /// City / region the listing is in.
  final String? region;
  final int? daysOnMarket;
  final VehicleSellerType sellerType;
  final String? listingUrl;

  /// The aggregator/source the listing came from — always labelled, so
  /// aggregator data is never presented as Facebook Marketplace data
  /// (design §2.2: Meta offers no Marketplace data route).
  final String sourceLabel;
}
