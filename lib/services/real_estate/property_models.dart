library;

/// Normalized real-estate data models for the Snap2Sell property-value
/// feature (Workstream B, additive module).
///
/// HARD HONESTY RULE (applies to every model here): a null field means
/// "unknown / unavailable". We NEVER write a zero, an invented number, or
/// a guessed string in place of real data. The valuation layer treats null
/// as missing evidence and degrades confidence instead of fabricating.

/// Residential property types the detector can classify from a photo.
/// Mirrors the spec's classification list.
enum PropertyType {
  detachedHouse,
  townhouse,
  duplex,
  condo,
  apartment,
  acreage,
  residentialLot,
  multiFamily,
  unknown;

  String get label => switch (this) {
        PropertyType.detachedHouse => 'Detached house',
        PropertyType.townhouse => 'Townhouse',
        PropertyType.duplex => 'Duplex',
        PropertyType.condo => 'Condo',
        PropertyType.apartment => 'Apartment',
        PropertyType.acreage => 'Acreage',
        PropertyType.residentialLot => 'Residential lot',
        PropertyType.multiFamily => 'Multi-family',
        PropertyType.unknown => 'Residential property',
      };
}

/// Evidence provenance for ANY renovation/condition claim. These labels
/// are NEVER merged: a record keeps its label from capture to the report,
/// so the user can always tell what is proven vs. observed vs. inferred.
enum RenovationEvidence {
  /// PERMIT FOUND — confirmed by an official permit/assessment record.
  confirmedByRecords,

  /// USER-REPORTED RENOVATION — the owner told us.
  confirmedByUser,

  /// OBSERVED FROM PHOTO — Gemini's visual observation only
  /// ("Kitchen appears recently updated"), never a year, never a fact.
  observedFromPhoto,

  /// AI INFERENCE — an inference, explicitly not a fact.
  aiInference,

  unknown;

  String get label => switch (this) {
        RenovationEvidence.confirmedByRecords => 'CONFIRMED BY RECORDS',
        RenovationEvidence.confirmedByUser => 'CONFIRMED BY USER',
        RenovationEvidence.observedFromPhoto => 'OBSERVED FROM PHOTO',
        RenovationEvidence.aiInference => 'AI INFERENCE',
        RenovationEvidence.unknown => 'UNKNOWN',
      };
}

/// A renovation claim with its evidence label attached. [year] is only set
/// when confirmed by records or by the user — NEVER inferred from a photo.
class RenovationRecord {
  const RenovationRecord({
    required this.description,
    required this.evidence,
    this.sourceDetail,
    this.year,
  }) : assert(
          year == null ||
              evidence == RenovationEvidence.confirmedByRecords ||
              evidence == RenovationEvidence.confirmedByUser,
          'Renovation year must never be inferred from a photo.',
        );

  final String description;
  final RenovationEvidence evidence;

  /// e.g. "City of Chilliwack permit #2024-0117" or "entered by owner".
  final String? sourceDetail;
  final int? year;
}

/// One visual observation from a property photo. Always
/// OBSERVED FROM PHOTO — the analyzer that produces these may not set any
/// other evidence level.
class ConditionObservation {
  const ConditionObservation({
    required this.area,
    required this.observation,
    this.evidence = RenovationEvidence.observedFromPhoto,
  });

  /// e.g. "Kitchen", "Exterior", "Roof". "General" when not area-specific.
  final String area;

  /// e.g. "Kitchen appears recently updated." — visual only, no years.
  final String observation;
  final RenovationEvidence evidence;
}

/// User-confirmed property address. The address is the primary property
/// identifier and is NEVER guessed or inferred from a photo.
class PropertyAddress {
  const PropertyAddress({
    required this.street,
    required this.city,
    this.province = 'BC',
    this.postalCode,
  });

  final String street;
  final String city;
  final String province;
  final String? postalCode;

  bool get isComplete =>
      street.trim().isNotEmpty && city.trim().isNotEmpty;

  String get displayLine =>
      '$street, $city, $province${postalCode?.trim().isNotEmpty == true ? '  ${postalCode!.trim()}' : ''}';

  Map<String, dynamic> toJson() => {
        'street': street,
        'city': city,
        'province': province,
        'postalCode': postalCode,
      };
}

/// Property characteristics. [evidence] says where they came from —
// / provider data, user entry, or unknown. Photo-derived characteristics
/// stay in [ConditionObservation]s instead.
class PropertyCharacteristics {
  const PropertyCharacteristics({
    this.yearBuilt,
    this.lotSizeSqft,
    this.buildingAreaSqft,
    this.bedrooms,
    this.bathrooms,
    this.basementSuite,
    this.evidence = RenovationEvidence.unknown,
  });

  final int? yearBuilt;
  final double? lotSizeSqft;
  final double? buildingAreaSqft;
  final int? bedrooms;
  final double? bathrooms;
  final bool? basementSuite;
  final RenovationEvidence evidence;
}

/// BC Assessment (or equivalent) values. This is a DATA INPUT — the
/// valuation engine never treats it as market value, and the report labels
/// it separately from the estimated current market value.
class AssessmentData {
  const AssessmentData({
    this.landValue,
    this.improvementsValue,
    this.totalValue,
    this.assessmentYear,
    this.sourceLabel = 'BC Assessment',
  });

  final double? landValue;
  final double? improvementsValue;
  final double? totalValue;
  final int? assessmentYear;
  final String sourceLabel;
}

/// One municipal permit record. Absence of a permit is never presented as
/// proof that no renovation occurred.
class PermitRecord {
  const PermitRecord({
    required this.permitId,
    required this.type,
    required this.municipality,
    this.status,
    this.issuedDate,
    this.description,
  });

  final String permitId;
  final String type;
  final String municipality;
  final String? status;
  final String? issuedDate;
  final String? description;
}

/// One comparable sale, with the spec's similarity scoring. [salePrice]
/// null means the price is unknown — never zero.
class ComparableSale {
  const ComparableSale({
    required this.address,
    this.salePrice,
    this.saleDate,
    this.distanceKm,
    this.propertyType,
    this.buildingAreaSqft,
    this.lotSizeSqft,
    this.bedrooms,
    this.bathrooms,
    this.yearBuilt,
    this.similarityScore = 0,
    this.adjustments = const [],
  });

  final String address;
  final double? salePrice;
  final String? saleDate;
  final double? distanceKm;
  final String? propertyType;
  final double? buildingAreaSqft;
  final double? lotSizeSqft;
  final int? bedrooms;
  final double? bathrooms;
  final int? yearBuilt;

  /// 0..100 similarity to the subject property.
  final double similarityScore;

  /// Transparent adjustments applied vs. the subject (e.g. "+ larger lot").
  final List<String> adjustments;
}

/// Local market conditions snapshot (board stats, benchmark trends).
class MarketConditions {
  const MarketConditions({
    this.summary,
    this.benchmarkPriceChangePct,
    this.sourceLabel,
  });

  final String? summary;
  final double? benchmarkPriceChangePct;
  final String? sourceLabel;
}

enum ValuationConfidence { high, medium, low }

/// Valuation output. When [insufficientData] is true, low/mid/high are
/// ALL null and [reasons] explains what is missing. We never return zeros
/// disguised as a valuation.
class ValuationResult {
  const ValuationResult({
    this.estimatedLow,
    this.estimatedMid,
    this.estimatedHigh,
    required this.confidence,
    required this.insufficientData,
    this.reasons = const [],
    this.adjustments = const [],
    this.methodologyNote = '',
  });

  final double? estimatedLow;
  final double? estimatedMid;
  final double? estimatedHigh;
  final ValuationConfidence confidence;
  final bool insufficientData;

  /// Why this confidence level / what data is missing.
  final List<String> reasons;

  /// Transparent adjustments applied to comparables.
  final List<String> adjustments;
  final String methodologyNote;
}

/// The subject property's own sale history (most recent first).
/// A very recent arm's-length sale is supporting evidence — it anchors but
/// never replaces comparable sales.
class SubjectSale {
  const SubjectSale({
    required this.salePrice,
    required this.saleDate,
    this.sourceLabel = 'unknown source',
  });

  final double salePrice;
  final DateTime saleDate;
  final String sourceLabel;
}

/// The spec's normalized property record: address, characteristics,
/// assessment, permits, renovations, sales, comps, valuation.
class PropertyRecord {
  const PropertyRecord({
    this.address,
    required this.propertyType,
    this.characteristics,
    this.assessment,
    this.permitHistory = const [],
    this.knownRenovations = const [],
    this.conditionObservations = const [],
    this.recentSales = const [],
    this.comparableSales = const [],
    this.marketConditions,
    required this.valuation,
  });

  final PropertyAddress? address;
  final PropertyType propertyType;
  final PropertyCharacteristics? characteristics;
  final AssessmentData? assessment;
  final List<PermitRecord> permitHistory;
  final List<RenovationRecord> knownRenovations;
  final List<ConditionObservation> conditionObservations;

  /// The subject's own recent sale history (empty: no lawful source today).
  final List<SubjectSale> recentSales;
  final List<ComparableSale> comparableSales;
  final MarketConditions? marketConditions;
  final ValuationResult valuation;
}

/// Per-source status note shown in the report so the user can see exactly
/// which sources are live and which are placeholders.
class DataSourceNote {
  const DataSourceNote({
    required this.sourceName,
    required this.isLive,
    required this.detail,
  });

  final String sourceName;
  final bool isLive;
  final String detail;
}

/// Full property report handed to the UI.
class PropertyValuationReport {
  const PropertyValuationReport({
    required this.record,
    required this.generatedAt,
    required this.addressConfirmed,
    required this.dataSources,
    required this.nextStepMessage,
  });

  final PropertyRecord record;
  final DateTime generatedAt;

  /// True once the user has confirmed the address.
  final bool addressConfirmed;
  final List<DataSourceNote> dataSources;

  /// e.g. "Home detected. Add the property address for a full valuation."
  final String nextStepMessage;
}
