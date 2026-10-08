import '../models/ai_analysis_result.dart';

/// A resale price estimate for an identified product.
class PriceEstimate {
  const PriceEstimate({
    required this.low,
    required this.high,
    required this.suggested,
    required this.source,
    required this.tier,
  });

  final double low;
  final double high;
  final double suggested;

  /// Where the numbers came from, e.g. 'ai-estimate' or 'marketplace'.
  /// Shown to the user so estimates are never mistaken for appraisals.
  final String source;

  /// Pricing tier (Apple/Tesla patch): 1 = exact estimate for a fully
  /// identified variant; 2 = broader preliminary range for a product-family
  /// identification; 3 = no honest range available (all zeros — never
  /// fabricated). The UI labels tiers 2/3 instead of inventing numbers.
  final int tier;
}

/// Phase 9 — pricing architecture.
///
/// Pipeline: PHOTO → AI IDENTIFICATION → NORMALIZED BRAND/MODEL/NAME →
/// PRODUCT SEARCH / MARKETPLACE DATA → COMPARABLES → PRICE ESTIMATE.
///
/// Today only the AI-estimate step is wired ([AiEstimatePricingService]).
/// When a marketplace/product-search API is connected, add an
/// implementation of this interface (e.g. EbayMarketplacePricingService)
/// that looks up sold comparables for [ProductIdentification.brand],
/// [ProductIdentification.model], and [ProductIdentification.productFamily],
/// and swap it in where the service is constructed. The rest of the app
/// does not change.
abstract class PricingService {
  PriceEstimate estimatePrice(ProductIdentification identification);
}

/// Current implementation: uses the price range the vision model estimated
/// from the photo. Labeled 'ai-estimate' so the UI can say "AI estimate".
///
/// Tiering (Apple/Tesla patch): a product-family identification
/// ([ProgressiveIdentification.levelOf] == 'product_family') with a usable
/// range becomes tier 2 ("preliminary range"); no numbers at all is tier 3.
/// Exact identifications keep tier 1. Tiers never invent numbers — tier 3
/// stays all zeros.
class AiEstimatePricingService implements PricingService {
  @override
  PriceEstimate estimatePrice(ProductIdentification identification) {
    double low = identification.priceLow;
    double high = identification.priceHigh;
    double suggested = identification.suggestedPrice;
    final level = ProgressiveIdentification.levelOf(identification);
    if (low <= 0 && high <= 0 && suggested <= 0) {
      return const PriceEstimate(
        low: 0,
        high: 0,
        suggested: 0,
        source: 'ai-estimate',
        tier: 3,
      );
    }
    if (suggested <= 0) {
      suggested = low > 0 && high > 0 ? (low + high) / 2 : (high > 0 ? high : low);
    }
    if (low <= 0) low = suggested;
    if (high <= 0) high = suggested;
    return PriceEstimate(
      low: low,
      high: high,
      suggested: suggested,
      source: 'ai-estimate',
      tier: level == 'product_family' ? 2 : 1,
    );
  }
}
