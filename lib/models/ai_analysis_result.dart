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
    this.identificationLevel = 'exact',
    this.pricingTier = 1,
    this.partialNotice,
  });

  final String title;
  final String category;
  final ItemCondition condition;
  final double priceLow;
  final double priceHigh;
  final double suggestedPrice;
  final String description;

  /// 'exact' or 'product_family' (see [ProgressiveIdentification.levelOf]).
  final String identificationLevel;

  /// 1 = exact estimate, 2 = preliminary range, 3 = no range available.
  final int pricingTier;

  /// Soft follow-up shown when the product family was identified but not
  /// the exact variant. The listing IS created; this is guidance, not a
  /// block. Null for ordinary exact identifications.
  final String? partialNotice;

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
      identificationLevel:
          json['identificationLevel'] as String? ?? 'exact',
      pricingTier: (json['pricingTier'] as num?)?.toInt() ?? 1,
      partialNotice: json['partialNotice'] as String?,
    );
  }

  /// Builds the listing draft from a [ProductIdentification]. Prices come
  /// from [PricingService]; everything else maps straight across.
  ///
  /// [pricingTier] labels the numbers honestly: 1 = exact estimate (no
  /// label), 2 = preliminary range, 3 = no range. Tier 2/3 notes are
  /// appended to the description; no number is ever invented here.
  factory AiAnalysisResult.fromIdentification(
    ProductIdentification id, {
    required double priceLow,
    required double priceHigh,
    required double suggestedPrice,
    int pricingTier = 1,
  }) {
    final title = id.suggestedTitle.isNotEmpty
        ? id.suggestedTitle
        : ([id.brand, id.productName, id.model]
                .where((s) => s.isNotEmpty)
                .join(' '))
            .trim();
    final level = ProgressiveIdentification.levelOf(id);
    var description = id.shortDescription.isNotEmpty
        ? '${id.shortDescription} (AI estimate — please confirm details before listing.)'
        : '';
    if (pricingTier == 2) {
      description = _withNote(description,
          'Preliminary estimated resale range — confirm the model/year for a more accurate estimate.');
    } else if (pricingTier == 3 && level == 'product_family') {
      description =
          _withNote(description, 'Exact pricing requires the model/year.');
    }
    return AiAnalysisResult(
      title: title.isEmpty ? 'Untitled item' : title,
      category: id.category.isNotEmpty ? id.category : 'Miscellaneous',
      condition: ItemConditionLabel.fromString(id.condition),
      priceLow: priceLow,
      priceHigh: priceHigh,
      suggestedPrice: suggestedPrice,
      description: description,
      identificationLevel: level,
      pricingTier: pricingTier,
      partialNotice: ProgressiveIdentification.noticeFor(id),
    );
  }

  static String _withNote(String description, String note) =>
      description.isEmpty ? note : '$description $note';

  Map<String, dynamic> toJson() => {
        'title': title,
        'category': category,
        'condition': condition.name,
        'priceLow': priceLow,
        'priceHigh': priceHigh,
        'suggestedPrice': suggestedPrice,
        'description': description,
        'identificationLevel': identificationLevel,
        'pricingTier': pricingTier,
        'partialNotice': partialNotice,
      };
}

/// Brand-gated progressive identification (the Apple/Tesla patch).
///
/// A single place for the fallback rules, shared by the backend service
/// (which decides whether a weak result still becomes a listing) and the
/// result mapping (which labels the listing and its pricing tier).
///
/// Nothing here touches any other brand: [isFamilyMatch] is false for
/// everything except the Apple and Tesla families below, so all existing
/// recognition behavior is preserved exactly.
class ProgressiveIdentification {
  ProgressiveIdentification._();

  /// Apple product families covered by the progressive-identification
  /// fallback. Ordered longest-first so "MacBook Pro" wins over "MacBook".
  static const List<String> appleFamilies = [
    'MacBook Pro',
    'MacBook Air',
    'iPad Pro',
    'iPad Air',
    'iPad',
    'MacBook',
  ];

  /// Tesla model families covered by the fallback.
  static const List<String> teslaFamilies = [
    'Model 3',
    'Model Y',
    'Model S',
    'Model X',
  ];

  /// The matched family display name ("MacBook Pro"), or null when the
  /// identification is not one of the gated Apple/Tesla families.
  static String? matchedFamily(ProductIdentification id) {
    final brand = id.brand.trim().toLowerCase();
    final List<String>? families;
    if (brand == 'apple') {
      families = appleFamilies;
    } else if (brand == 'tesla') {
      families = teslaFamilies;
    } else {
      return null;
    }
    final haystack =
        '${id.productName} ${id.productFamily}'.toLowerCase();
    for (final family in families) {
      if (haystack.contains(family.toLowerCase())) return family;
    }
    return null;
  }

  /// True when the result is a confident-enough Apple/Tesla family
  /// identification. [minConfidence] is the caller's existing confidence
  /// bar — this gate never lowers it, it only stops treating
  /// "family known, exact variant unknown" as a failure for these brands.
  static bool isFamilyMatch(ProductIdentification id,
      {required int minConfidence}) {
    if (matchedFamily(id) == null) return false;
    return id.confidence >= minConfidence;
  }

  /// 'product_family' when only the brand + family is known,
  /// otherwise 'exact'. Brand-gated: never 'product_family' for other
  /// brands, so their pricing/labeling is untouched.
  static String levelOf(ProductIdentification id) {
    if (id.identificationLevel == 'product_family') return 'product_family';
    final family = matchedFamily(id);
    if (family == null) return 'exact';
    if (id.needsMoreInformation) return 'product_family';
    // Exact model unknown (empty) for a gated family: the backend's
    // honesty rules forbid inventing it, so this is a family-level result.
    if (id.model.trim().isEmpty) return 'product_family';
    return 'exact';
  }

  /// Soft, non-blocking follow-up for a family-level identification, or
  /// null when the identification is exact. Never invents specs — it only
  /// names what is already known and suggests the optional refinement.
  static String? noticeFor(ProductIdentification id) {
    if (levelOf(id) != 'product_family') return null;
    final family = matchedFamily(id);
    if (family == null) return null;
    final name = '${id.brand.trim()} $family';
    if (id.brand.trim().toLowerCase() == 'apple') {
      return 'Product identified: $name.\n\n'
          'We can create your listing now.\n\n'
          'For a more accurate price, add a photo of the model number on '
          'the bottom of the laptop or the About This Mac screen.';
    }
    return 'Product identified: $name.\n\n'
        'We can create your listing now.\n\n'
        'For a more accurate price, add the year and trim, or a photo of '
        'the VIN or vehicle-information screen.';
  }
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
    this.identificationLevel = '',
    this.needsMoreInformation = false,
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

  /// 'exact' | 'product_family' as returned by the backend prompt.
  /// Empty for responses from before the field existed.
  final String identificationLevel;

  /// True when a model-number / About This Mac / VIN photo would sharpen
  /// the result. Informational only — never blocks the listing.
  final bool needsMoreInformation;

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
      identificationLevel: _str(json['identification_level']),
      needsMoreInformation:
          json['needs_more_information'] as bool? ?? false,
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
