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

/// Thrown when the live AI service cannot analyze a photo.
class AiServiceException implements Exception {
  AiServiceException(this.message);
  final String message;

  @override
  String toString() => 'AiServiceException: $message';
}
