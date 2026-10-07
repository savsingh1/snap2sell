import '../models/ai_analysis_result.dart';

/// A resale price estimate for an identified product.
class PriceEstimate {
  const PriceEstimate({
    required this.low,
    required this.high,
    required this.suggested,
    required this.source,
  });

  final double low;
  final double high;
  final double suggested;

  /// Where the numbers came from, e.g. 'ai-estimate' or 'marketplace'.
  /// Shown to the user so estimates are never mistaken for appraisals.
  final String source;
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
class AiEstimatePricingService implements PricingService {
  @override
  PriceEstimate estimatePrice(ProductIdentification identification) {
    double low = identification.priceLow;
    double high = identification.priceHigh;
    double suggested = identification.suggestedPrice;
    if (low <= 0 && high <= 0 && suggested <= 0) {
      return const PriceEstimate(
        low: 0,
        high: 0,
        suggested: 0,
        source: 'ai-estimate',
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
    );
  }
}
