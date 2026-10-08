library;

/// Real-estate classification for the Snap2Sell photo pipeline (Workstream B).
///
/// ADDITIVE ONLY: this runs AFTER the existing product/vehicle analysis and
/// never changes it. When it detects real estate, the result is routed to
/// the new property-valuation flow; otherwise the caller passes the result
/// through untouched.
///
/// HOW DETECTION WORKS TODAY: the deployed backend prompt has no Real
/// Estate category yet (its categories are Furniture, Electronics, ...,
/// Miscellaneous), so this detector matches residential-property keywords
/// in the identification's title/category/description/keywords. This is an
/// app-side heuristic — the long-term fix is the backend's dedicated
/// real-estate classification prompt (see functions/analyze-product,
/// REAL_ESTATE_PROMPT — UNDEPLOYED, placeholder).
///
/// HONESTY: detection only ever says "this photo looks like a residential
/// property of type X". It NEVER infers an address, a value, or a year.

import '../../models/ai_analysis_result.dart';
import 'property_models.dart';

/// Detects residential real estate in an [AiAnalysisResult].
///
/// Returns the detected [PropertyType], or null when the photo is not
/// real estate (the normal product/vehicle flow continues unchanged).
class RealEstateDetector {
  RealEstateDetector._();

  /// Keyword patterns per property type, ordered longest-first so
  /// "detached house" wins over "house" and "townhouse" never matches
  /// inside "house". Word boundaries keep "dollhouse"/"warehouse" out.
  static const List<MapEntry<PropertyType, List<String>>> _patterns = [
    MapEntry(PropertyType.multiFamily, [
      'multi-family',
      'multi family',
      'multifamily',
      'fourplex',
      'triplex',
    ]),
    MapEntry(PropertyType.townhouse, [
      'townhouse',
      'town house',
      'townhome',
      'town home',
      'row house',
      'rowhouse',
    ]),
    MapEntry(PropertyType.duplex, [
      'duplex',
      'half duplex',
      'side-by-side',
    ]),
    MapEntry(PropertyType.condo, [
      'condominium',
      'condo',
    ]),
    MapEntry(PropertyType.apartment, [
      'apartment building',
      'apartment',
    ]),
    MapEntry(PropertyType.detachedHouse, [
      'detached house',
      'single-family home',
      'single family home',
      'single-family house',
      'single family house',
      'residential house',
      'farmhouse',
      'bungalow',
      'rancher',
      'mansion',
      'cottage',
      'house',
      'home exterior',
      'residential home',
    ]),
    MapEntry(PropertyType.acreage, [
      'acreage',
      'rural property',
      'farm land',
      'farmland',
    ]),
    MapEntry(PropertyType.residentialLot, [
      'residential lot',
      'vacant lot',
      'empty lot',
      'building lot',
    ]),
  ];

  /// Runs detection over the user-visible analysis result. Pure function —
  /// no network, no guessing beyond the keyword match.
  static PropertyType? detectFromResult(AiAnalysisResult result) {
    final haystack =
        '${result.title} ${result.category} ${result.description}'
            .toLowerCase();
    for (final entry in _patterns) {
      for (final keyword in entry.value) {
        final regex = RegExp(
          '\\b${RegExp.escape(keyword)}\\b',
          caseSensitive: false,
        );
        if (regex.hasMatch(haystack)) return entry.key;
      }
    }
    return null;
  }

  /// True when the result is real estate (any type).
  static bool isRealEstate(AiAnalysisResult result) =>
      detectFromResult(result) != null;
}
