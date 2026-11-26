library;

/// Vehicle-valuation data-source architecture (Valuation Phase 0),
/// mirroring the real-estate provider pattern: interfaces, honest
/// placeholder implementations, and a bundle the app wires once.
///
/// DATA-SOURCE STATUS (2026-11-25, per the design's verification):
/// - VinDecodeProvider ....... LIVE — NHTSA vPIC (free, no key)
/// - GuideValueProvider ...... PLACEHOLDER — guide values are licensed
///   (Canadian Black Book is sales-led; CARFAX Canada is contract-only;
///   MarketCheck / Cardog are the Phase 1 self-serve route)
/// - VehicleCompsProvider .... PLACEHOLDER — no official read API exists
///   for Facebook Marketplace, AutoTrader.ca, Kijiji Autos or CarGurus;
///   live comps arrive with a MarketCheck / Cardog key in Phase 1.
///
/// NOTHING in this file returns invented vehicle values.

import '../real_estate/providers.dart';
import 'vehicle_models.dart';
import 'vpic_vin_decode_provider.dart';

/// Normalizes a VIN into a [VehicleIdentity] (trim/engine/drivetrain).
/// An identifier step only — never a valuation source.
abstract class VinDecodeProvider {
  String get name;
  Future<ProviderResult<VehicleIdentity>> decodeVin(String vin);
}

/// Licensed guide values (wholesale / trade-in / retail / private-party).
abstract class GuideValueProvider {
  String get name;
  Future<ProviderResult<GuideValue>> getGuideValue(VehicleQuery query);
}

/// Live asking-price comparables for the same vehicle in the same market.
abstract class VehicleCompsProvider {
  String get name;
  Future<ProviderResult<List<VehicleComp>>> getComps(VehicleQuery query);
}

// ---------------------------------------------------------------------------
// Unavailable (placeholder) implementations — the honest defaults.
// ---------------------------------------------------------------------------

/// PLACEHOLDER / FUTURE INTEGRATION.
///
/// WHY: the Canadian guide sources are licensed. Canadian Black Book
/// sells API access through its sales team (dealer/lender-grade, price
/// not published) and CARFAX Canada's Valuation API is contract-only.
/// Kelley Blue Book has NO Canadian product, so there is no "Blue Book"
/// feed to connect for Canadian vehicles.
///
/// WHAT WOULD MAKE IT LIVE: a Canadian Black Book API licence or a
/// CARFAX Canada contract (Phase 2), or — sooner — a MarketCheck / Cardog
/// API key (Phase 1), whose value would be labelled as a market-derived
/// estimate, never as a Black Book value.
class UnavailableGuideValueProvider implements GuideValueProvider {
  const UnavailableGuideValueProvider();

  @override
  String get name => 'Guide value (Canadian Black Book / CARFAX Canada)';

  @override
  Future<ProviderResult<GuideValue>> getGuideValue(
      VehicleQuery query) async {
    return const ProviderResult.unavailable(
      providerName: 'Guide value (Canadian Black Book / CARFAX Canada)',
      unavailableReason:
          'Guide values are licensed data and no guide licence is connected.',
      whatWouldMakeItLive:
          'a Canadian Black Book API licence or CARFAX Canada contract (Phase 2), or a MarketCheck / Cardog API key for a labelled market estimate (Phase 1).',
    );
  }
}

/// PLACEHOLDER / FUTURE INTEGRATION.
///
/// WHY: there is NO official read API for Facebook Marketplace,
/// AutoTrader.ca, Kijiji Autos or CarGurus listings, and scraping them
/// (directly or via a vendor) is excluded by the design at every phase.
///
/// WHAT WOULD MAKE IT LIVE: a MarketCheck API key (Inventory Search +
/// Private Party Search, Canada model) or a Cardog key (Phase 1) —
/// labelled as aggregator data, never as Facebook data. Until then the
/// report offers the user a prefilled Facebook Marketplace search link
/// for their own browsing (see ValuationDeepLinks).
class UnavailableVehicleCompsProvider implements VehicleCompsProvider {
  const UnavailableVehicleCompsProvider();

  @override
  String get name => 'Live listing comparables';

  @override
  Future<ProviderResult<List<VehicleComp>>> getComps(
      VehicleQuery query) async {
    return const ProviderResult.unavailable(
      providerName: 'Live listing comparables',
      unavailableReason:
          'No official listings API is connected; Facebook Marketplace and the Canadian listing sites offer no data feed to apps.',
      whatWouldMakeItLive:
          'a MarketCheck or Cardog API key (Phase 1), labelled as aggregator data.',
    );
  }
}

// ---------------------------------------------------------------------------
// Bundle (dependency injection)
// ---------------------------------------------------------------------------

/// All vehicle providers in one place. Phase 0 wiring: VIN decode is
/// live via the free NHTSA vPIC API; guide values and comps stay honest
/// placeholders until their licensed/self-serve phases.
class VehicleProviders {
  const VehicleProviders({
    this.vinDecode = const NhtsaVpicVinDecodeProvider(),
    this.guideValue = const UnavailableGuideValueProvider(),
    this.comps = const UnavailableVehicleCompsProvider(),
  });

  final VinDecodeProvider vinDecode;
  final GuideValueProvider guideValue;
  final VehicleCompsProvider comps;

  /// The current production wiring (Phase 0).
  static const VehicleProviders defaults = VehicleProviders();
}
