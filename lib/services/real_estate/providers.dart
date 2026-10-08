library;

/// Real-estate data-source architecture (spec: adapters, not hard-coded to
/// one website).
///
/// Every provider below is an interface. The default bundle wires the
/// *unavailable* implementations, each of which documents WHY it is
/// unavailable and WHAT IT WOULD TAKE to make it live (API credentials /
/// access needed). The analyzer degrades gracefully: an unavailable source
/// lowers valuation confidence but never fails the valuation and never
/// produces fabricated data.
///
/// DATA-SOURCE STATUS (2026-10-07):
/// - PropertyAssessmentProvider ......... PLACEHOLDER / FUTURE INTEGRATION
/// - PropertyDetailsProvider ............ PLACEHOLDER / FUTURE INTEGRATION
/// - PermitProvider ..................... PLACEHOLDER / FUTURE INTEGRATION
/// - ComparableSalesProvider ............ PLACEHOLDER / FUTURE INTEGRATION
/// - MarketDataProvider ................. PLACEHOLDER / FUTURE INTEGRATION
///
/// NOTHING in this file returns invented property data.

import 'property_models.dart';

/// Honest status of a data source. Shown in the report per source.
enum DataSourceStatus {
  /// Actually returning live, authorized data.
  workingLiveData,

  /// Interface exists; no live source wired yet. The app says so.
  placeholderFutureIntegration,
}

/// Result of one provider call. On [DataSourceStatus.placeholderFutureIntegration]
/// [data] is null and [unavailableReason]/[whatWouldMakeItLive] explain why.
class ProviderResult<T> {
  const ProviderResult.available({
    required this.providerName,
    required this.data,
  })  : status = DataSourceStatus.workingLiveData,
        unavailableReason = null,
        whatWouldMakeItLive = null;

  const ProviderResult.unavailable({
    required this.providerName,
    required this.unavailableReason,
    required this.whatWouldMakeItLive,
  })  : status = DataSourceStatus.placeholderFutureIntegration,
        data = null;

  final DataSourceStatus status;
  final String providerName;
  final T? data;
  final String? unavailableReason;
  final String? whatWouldMakeItLive;

  bool get isAvailable => status == DataSourceStatus.workingLiveData;

  DataSourceNote toNote() => DataSourceNote(
        sourceName: providerName,
        isLive: isAvailable,
        detail: isAvailable
            ? 'Live data'
            : '${unavailableReason ?? 'Unavailable.'} '
                'To enable: ${whatWouldMakeItLive ?? 'integration work required.'}',
      );
}

// ---------------------------------------------------------------------------
// Interfaces
// ---------------------------------------------------------------------------

/// BC Assessment / property-assessment values for an address.
abstract class PropertyAssessmentProvider {
  String get name;
  Future<ProviderResult<AssessmentData>> getAssessment(
      PropertyAddress address);
}

/// Structural property characteristics (beds, baths, sqft, lot, year built).
abstract class PropertyDetailsProvider {
  String get name;
  Future<ProviderResult<PropertyCharacteristics>> getDetails(
      PropertyAddress address);
}

/// Municipal building-permit history.
abstract class PermitProvider {
  String get name;
  Future<ProviderResult<List<PermitRecord>>> getPermits(
      PropertyAddress address);
}

/// Authorized sold-data comparables near the subject property.
abstract class ComparableSalesProvider {
  String get name;
  Future<ProviderResult<List<ComparableSale>>> getComparables({
    required PropertyAddress address,
    required PropertyType propertyType,
    PropertyCharacteristics? characteristics,
  });
}

/// Local market conditions (board stats, benchmark trends).
abstract class MarketDataProvider {
  String get name;
  Future<ProviderResult<MarketConditions>> getMarketConditions({
    required String city,
    String province = 'BC',
  });
}

// ---------------------------------------------------------------------------
// Unavailable (placeholder) implementations — the honest defaults.
// ---------------------------------------------------------------------------

/// PLACEHOLDER / FUTURE INTEGRATION.
///
/// WHY: BC Assessment has NO public API. There is no lawful endpoint we
/// can call for assessed values today.
///
/// WHAT WOULD MAKE IT LIVE: a licensed data agreement with BC Assessment,
/// or a contract + API key with a paid property-data vendor that is
/// authorized to redistribute BC Assessment data.
class UnavailableAssessmentProvider implements PropertyAssessmentProvider {
  const UnavailableAssessmentProvider();

  @override
  String get name => 'BC Assessment lookup';

  @override
  Future<ProviderResult<AssessmentData>> getAssessment(
      PropertyAddress address) async {
    return const ProviderResult.unavailable(
      providerName: 'BC Assessment lookup',
      unavailableReason:
          'BC Assessment has no public API, so assessed values cannot be retrieved automatically.',
      whatWouldMakeItLive:
          'a licensed data agreement with BC Assessment or a paid property-data vendor API key.',
    );
  }
}

/// PLACEHOLDER / FUTURE INTEGRATION.
///
/// WHY: no authorized property-characteristics feed is connected.
///
/// WHAT WOULD MAKE IT LIVE: a paid property-data vendor API key
/// (beds/baths/sqft/lot/year-built), or user-entered details (which the
/// app already supports and labels CONFIRMED BY USER).
class UnavailableDetailsProvider implements PropertyDetailsProvider {
  const UnavailableDetailsProvider();

  @override
  String get name => 'Property details lookup';

  @override
  Future<ProviderResult<PropertyCharacteristics>> getDetails(
      PropertyAddress address) async {
    return const ProviderResult.unavailable(
      providerName: 'Property details lookup',
      unavailableReason:
          'No authorized property-characteristics source is connected.',
      whatWouldMakeItLive:
          'a paid property-data vendor API key, or owner-entered details (supported today, labeled CONFIRMED BY USER).',
    );
  }
}

/// PLACEHOLDER / FUTURE INTEGRATION.
///
/// WHY: there is NO unified municipal permit API. Permits live with each
/// municipality/regional district in different systems.
///
/// WHAT WOULD MAKE IT LIVE: one adapter per municipality, built on lawful
/// public sources where they exist (some BC cities publish permit datasets
/// on open-data portals such as Socrata/CKAN; others require a data-sharing
/// agreement). Each adapter is a separate integration — e.g. Vancouver,
/// Surrey, Burnaby, Richmond, Abbotsford, Chilliwack, Langley, Coquitlam,
/// Delta, New Westminster, then more.
class UnavailablePermitProvider implements PermitProvider {
  const UnavailablePermitProvider();

  @override
  String get name => 'Municipal permit lookup';

  @override
  Future<ProviderResult<List<PermitRecord>>> getPermits(
      PropertyAddress address) async {
    return const ProviderResult.unavailable(
      providerName: 'Municipal permit lookup',
      unavailableReason:
          'No unified permit API exists; permits are held per municipality and none are integrated yet.',
      whatWouldMakeItLive:
          'a per-municipality adapter (open-data portal where published, or a municipal data-sharing agreement).',
    );
  }
}

/// PLACEHOLDER / FUTURE INTEGRATION.
///
/// WHY: MLS sold data requires licensed realtor access (CREA DDF / board
/// feed), which we do not have. We do NOT scrape restricted systems and we
/// do NOT invent comparables.
///
/// WHAT WOULD MAKE IT LIVE: a licensed realtor credential with an
/// authorized sold-data feed, or a contract + API key with a licensed
/// property-data vendor. Until then the comparable-sales engine has no
/// lawful input and the valuation stays in its honest insufficient-data
/// state.
class UnavailableComparableSalesProvider
    implements ComparableSalesProvider {
  const UnavailableComparableSalesProvider();

  @override
  String get name => 'Comparable sales lookup';

  @override
  Future<ProviderResult<List<ComparableSale>>> getComparables({
    required PropertyAddress address,
    required PropertyType propertyType,
    PropertyCharacteristics? characteristics,
  }) async {
    return const ProviderResult.unavailable(
      providerName: 'Comparable sales lookup',
      unavailableReason:
          'MLS sold data requires licensed realtor access, which is not connected.',
      whatWouldMakeItLive:
          'a licensed realtor credential with an authorized sold-data feed, or a licensed property-data vendor API key.',
    );
  }
}

/// PLACEHOLDER / FUTURE INTEGRATION.
///
/// WHY: no market-statistics feed is connected.
///
/// WHAT WOULD MAKE IT LIVE: board-published market statistics ingested
/// under license, or a licensed market-data vendor API key.
class UnavailableMarketDataProvider implements MarketDataProvider {
  const UnavailableMarketDataProvider();

  @override
  String get name => 'Local market data';

  @override
  Future<ProviderResult<MarketConditions>> getMarketConditions({
    required String city,
    String province = 'BC',
  }) async {
    return const ProviderResult.unavailable(
      providerName: 'Local market data',
      unavailableReason: 'No market-statistics feed is connected.',
      whatWouldMakeItLive:
          'board-published market statistics under license, or a licensed market-data vendor API key.',
    );
  }
}

// ---------------------------------------------------------------------------
// Bundle (dependency injection)
// ---------------------------------------------------------------------------

/// All providers in one place. Defaults are the honest unavailable
/// implementations; a future integration swaps in live adapters without
/// touching the analyzer or the UI.
class RealEstateProviders {
  const RealEstateProviders({
    this.assessment = const UnavailableAssessmentProvider(),
    this.details = const UnavailableDetailsProvider(),
    this.permits = const UnavailablePermitProvider(),
    this.comparables = const UnavailableComparableSalesProvider(),
    this.market = const UnavailableMarketDataProvider(),
  });

  final PropertyAssessmentProvider assessment;
  final PropertyDetailsProvider details;
  final PermitProvider permits;
  final ComparableSalesProvider comparables;
  final MarketDataProvider market;

  /// The current production wiring: every source is a documented
  /// placeholder. The analyzer treats them as such.
  static const RealEstateProviders defaults = RealEstateProviders();
}
