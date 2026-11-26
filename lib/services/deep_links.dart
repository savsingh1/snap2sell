library;

/// External deep links for the valuation flows (Valuation Phase 0).
///
/// These are LINK BUILDERS ONLY: they open the user's own browsing on
/// their own accounts. No data comes back into the app from any of them —
/// that is the sanctioned pattern for sources whose terms do not allow
/// automated access (design §2.2 / §3.2):
///
/// - **BC Assessment** free search is personal, non-commercial use only,
///   and BCA publishes no prefilled-address URL. The link opens the
///   official search; the user enters the same address they confirmed in
///   the app and can type the assessed value back in (CONFIRMED BY USER).
/// - **Zealty** sold prices sit behind the user's own free registered
///   account (board VOW rules). The link opens Zealty's page for the
///   property's city (URL pattern verified live: /region/bc/<city>),
///   where the user searches their exact address for sold history.
/// - **Facebook Marketplace** has no data API. The link opens a prefilled
///   Marketplace search for the vehicle in the user's own Facebook
///   session; the user compares prices themselves.

import 'real_estate/property_models.dart';

class ValuationDeepLinks {
  ValuationDeepLinks._();

  /// BC Assessment's official property search (entry point — BCA offers
  /// no stable address-prefilled URL).
  static Uri bcAssessmentSearch(PropertyAddress address) =>
      Uri.https('www.bcassessment.ca', '/');

  /// Zealty's page for the property's city, the entry point to its
  /// sold-history search (sold data needs the user's free Zealty account).
  static Uri zealtySoldHistory(PropertyAddress address) => Uri.https(
        'www.zealty.ca',
        '/region/bc/${_slug(address.city)}',
      );

  /// A prefilled Facebook Marketplace search for a vehicle, described by
  /// the user-confirmed vehicle text (e.g. "2019 Honda Civic").
  static Uri facebookMarketplaceVehicleSearch(String vehicleDescription) =>
      Uri.https(
        'www.facebook.com',
        '/marketplace/search/',
        {'query': vehicleDescription.trim()},
      );

  static String _slug(String city) => city
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
