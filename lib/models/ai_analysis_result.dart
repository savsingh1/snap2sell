import 'item.dart';

/// The structured result returned by an [AiService] after analysing a photo.
class AiAnalysisResult {
  const AiAnalysisResult({
    required this.title,
    required this.category,
    required this.condition,
    required this.priceLow,
    required this.priceHigh,
    required this.suggestedPrice,
    required this.description,
  });

  final String title;
  final String category;
  final ItemCondition condition;
  final double priceLow;
  final double priceHigh;
  final double suggestedPrice;
  final String description;

  factory AiAnalysisResult.fromJson(Map<String, dynamic> json) {
    return AiAnalysisResult(
      title: json['title'] as String? ?? 'Untitled item',
      category: json['category'] as String? ?? 'Miscellaneous',
      condition:
          ItemConditionLabel.fromString(json['condition'] as String?),
      priceLow: (json['priceLow'] as num?)?.toDouble() ?? 0,
      priceHigh: (json['priceHigh'] as num?)?.toDouble() ?? 0,
      suggestedPrice: (json['suggestedPrice'] as num?)?.toDouble() ?? 0,
      description: json['description'] as String? ?? '',
    );
  }

  /// Builds the listing draft from a [ProductIdentification]. Prices come
  /// from [PricingService]; everything else maps straight across.
  factory AiAnalysisResult.fromIdentification(
    ProductIdentification id, {
    required double priceLow,
    required double priceHigh,
    required double suggestedPrice,
  }) {
    final title = id.suggestedTitle.isNotEmpty
        ? id.suggestedTitle
        : ([id.brand, id.productName, id.model]
                .where((s) => s.isNotEmpty)
                .join(' '))
            .trim();
    final description = id.shortDescription.isNotEmpty
        ? '${id.shortDescription} (AI estimate — please confirm details before listing.)'
        : '';
    return AiAnalysisResult(
      title: title.isEmpty ? 'Untitled item' : title,
      category: id.category.isNotEmpty ? id.category : 'Miscellaneous',
      condition: ItemConditionLabel.fromString(id.condition),
      priceLow: priceLow,
      priceHigh: priceHigh,
      suggestedPrice: suggestedPrice,
      description: description,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'category': category,
        'condition': condition.name,
        'priceLow': priceLow,
        'priceHigh': priceHigh,
        'suggestedPrice': suggestedPrice,
        'description': description,
      };
}

/// Full structured product identification returned by the backend
/// (see the Phase-5 prompt). This is the AI's *observation*; the listing
/// draft derived from it is in [AiAnalysisResult].
class ProductIdentification {
  const ProductIdentification({
    required this.recognized,
    required this.brand,
    required this.productName,
    required this.model,
    required this.productFamily,
    required this.category,
    required this.subcategory,
    required this.color,
    required this.condition,
    required this.visibleDamage,
    required this.includedAccessories,
    required this.missingParts,
    required this.searchKeywords,
    required this.suggestedTitle,
    required this.shortDescription,
    required this.priceLow,
    required this.priceHigh,
    required this.suggestedPrice,
    required this.confidence,
    required this.needsMorePhotos,
    required this.recommendedPhotos,
  });

  final bool recognized;
  final String brand;
  final String productName;
  final String model;
  final String productFamily;
  final String category;
  final String subcategory;
  final String color;
  final String condition;
  final List<String> visibleDamage;
  final List<String> includedAccessories;
  final List<String> missingParts;
  final List<String> searchKeywords;
  final String suggestedTitle;
  final String shortDescription;
  final double priceLow;
  final double priceHigh;
  final double suggestedPrice;
  final int confidence; // 0..100
  final bool needsMorePhotos;
  final List<String> recommendedPhotos;

  static List<String> _stringList(dynamic v) => (v as List<dynamic>?)
          ?.map((e) => e.toString())
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList() ??
      const [];

  static String _str(dynamic v) => (v as String? ?? '').trim();

  factory ProductIdentification.fromJson(Map<String, dynamic> json) {
    final conf = (json['confidence'] as num?)?.toInt() ?? 0;
    return ProductIdentification(
      recognized: json['recognized'] as bool? ?? false,
      brand: _str(json['brand']),
      productName: _str(json['product_name']),
      model: _str(json['model']),
      productFamily: _str(json['product_family']),
      category: _str(json['category']),
      subcategory: _str(json['subcategory']),
      color: _str(json['color']),
      condition: _str(json['condition']),
      visibleDamage: _stringList(json['visible_damage']),
      includedAccessories: _stringList(json['included_accessories']),
      missingParts: _stringList(json['missing_parts']),
      searchKeywords: _stringList(json['search_keywords']),
      suggestedTitle: _str(json['suggested_title']),
      shortDescription: _str(json['short_description']),
      priceLow: (json['price_low'] as num?)?.toDouble() ?? 0,
      priceHigh: (json['price_high'] as num?)?.toDouble() ?? 0,
      suggestedPrice: (json['suggested_price'] as num?)?.toDouble() ?? 0,
      confidence: conf.clamp(0, 100),
      needsMorePhotos: json['needs_more_photos'] as bool? ?? false,
      recommendedPhotos: _stringList(json['recommended_photos']),
    );
  }
}

/// Internal error categories. The UI only ever shows [friendlyMessage];
/// [message] is for debug logs (already sanitized — never contains keys,
/// URLs, or stack traces).
enum AiErrorCategory {
  network,
  timeout,
  auth,
  rateLimit,
  model,
  badImage,
  invalidResponse,
  lowConfidence,
}

/// Thrown when the AI backend cannot analyze a photo.
class AiServiceException implements Exception {
  AiServiceException(this.message, {this.category = AiErrorCategory.model});

  final String message;
  final AiErrorCategory category;

  /// User-facing text. Never technical, never leaks internals.
  String get friendlyMessage {
    switch (category) {
      case AiErrorCategory.network:
        return 'We had trouble reaching the analysis service. Check your connection and try again.';
      case AiErrorCategory.timeout:
        return 'Analysis took too long. Check your connection and try again.';
      case AiErrorCategory.auth:
        return 'The analysis service is unavailable right now. Try again later.';
      case AiErrorCategory.rateLimit:
        return 'Lots of people are analyzing photos right now. Wait a moment and try again.';
      case AiErrorCategory.badImage:
        return 'That photo could not be read. Try a clearer photo of the item.';
      case AiErrorCategory.invalidResponse:
        return "We couldn't make sense of the analysis. Try again or enter the details manually.";
      case AiErrorCategory.lowConfidence:
        return message; // already a friendly photo-guidance message
      case AiErrorCategory.model:
        return "We couldn't analyze this photo right now. Try again or enter the details manually.";
    }
  }

  @override
  String toString() => 'AiServiceException($category): $message';
}
