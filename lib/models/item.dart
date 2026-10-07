/// Condition grades the AI assigns (and the user can adjust).
enum ItemCondition { likeNew, excellent, good, fair, poor }

extension ItemConditionLabel on ItemCondition {
  String get label {
    switch (this) {
      case ItemCondition.likeNew:
        return 'Like New';
      case ItemCondition.excellent:
        return 'Excellent';
      case ItemCondition.good:
        return 'Good';
      case ItemCondition.fair:
        return 'Fair';
      case ItemCondition.poor:
        return 'Poor';
    }
  }

  /// Parse back from the stored string; defaults to [ItemCondition.good].
  static ItemCondition fromString(String? value) {
    return ItemCondition.values.firstWhere(
      (c) => c.name == value,
      orElse: () => ItemCondition.good,
    );
  }
}

/// Where the listing sits in the user's flow.
enum ListingStatus { draft, ready, posted, sold }

extension ListingStatusLabel on ListingStatus {
  String get label {
    switch (this) {
      case ListingStatus.draft:
        return 'Draft';
      case ListingStatus.ready:
        return 'Ready to post';
      case ListingStatus.posted:
        return 'Posted';
      case ListingStatus.sold:
        return 'Sold';
    }
  }

  static ListingStatus fromString(String? value) {
    return ListingStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => ListingStatus.draft,
    );
  }
}

/// A single item the user snapped, with its AI-generated listing data.
class Item {
  Item({
    required this.id,
    required this.photoPath,
    required this.title,
    required this.category,
    required this.condition,
    required this.priceLow,
    required this.priceHigh,
    required this.suggestedPrice,
    required this.description,
    List<String>? platforms,
    this.status = ListingStatus.draft,
    DateTime? createdAt,
  })  : platforms = platforms ?? <String>[],
        createdAt = createdAt ?? DateTime.now();

  final String id;

  /// Local file path of the snapped photo (copied into app documents).
  final String photoPath;

  String title;
  String category;
  ItemCondition condition;
  double priceLow;
  double priceHigh;
  double suggestedPrice;
  String description;
  List<String> platforms;
  ListingStatus status;
  final DateTime createdAt;

  String get priceDisplay => '\$${suggestedPrice.toStringAsFixed(0)}';
  String get rangeDisplay =>
      '\$${priceLow.toStringAsFixed(0)} – \$${priceHigh.toStringAsFixed(0)}';

  Item copyWith({
    String? title,
    String? category,
    ItemCondition? condition,
    double? priceLow,
    double? priceHigh,
    double? suggestedPrice,
    String? description,
    List<String>? platforms,
    ListingStatus? status,
  }) {
    return Item(
      id: id,
      photoPath: photoPath,
      title: title ?? this.title,
      category: category ?? this.category,
      condition: condition ?? this.condition,
      priceLow: priceLow ?? this.priceLow,
      priceHigh: priceHigh ?? this.priceHigh,
      suggestedPrice: suggestedPrice ?? this.suggestedPrice,
      description: description ?? this.description,
      platforms: platforms ?? List<String>.from(this.platforms),
      status: status ?? this.status,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'photoPath': photoPath,
        'title': title,
        'category': category,
        'condition': condition.name,
        'priceLow': priceLow,
        'priceHigh': priceHigh,
        'suggestedPrice': suggestedPrice,
        'description': description,
        'platforms': platforms,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Item.fromJson(Map<String, dynamic> json) => Item(
        id: json['id'] as String,
        photoPath: json['photoPath'] as String,
        title: json['title'] as String? ?? '',
        category: json['category'] as String? ?? 'Miscellaneous',
        condition:
            ItemConditionLabel.fromString(json['condition'] as String?),
        priceLow: (json['priceLow'] as num?)?.toDouble() ?? 0,
        priceHigh: (json['priceHigh'] as num?)?.toDouble() ?? 0,
        suggestedPrice: (json['suggestedPrice'] as num?)?.toDouble() ?? 0,
        description: json['description'] as String? ?? '',
        platforms: (json['platforms'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            <String>[],
        status: ListingStatusLabel.fromString(json['status'] as String?),
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );
}
