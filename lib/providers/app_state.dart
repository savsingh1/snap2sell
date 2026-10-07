import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models/ai_analysis_result.dart';
import '../models/item.dart';
import '../services/ai_service.dart';
import '../services/listing_service.dart';
import '../services/storage_service.dart';

/// Labels shown on the Processing screen while the AI pipeline runs.
const List<String> kAnalysisSteps = [
  'Identifying item…',
  'Assessing condition…',
  'Fetching market prices…',
  'Writing your listing…',
];

/// Single source of truth for the app (wired with `provider`).
/// Owns the item list, the in-progress listing, and the AI pipeline.
class AppState extends ChangeNotifier {
  AppState({
    StorageService? storage,
    ListingService? listing,
    AiService? aiService,
    ImagePicker? imagePicker,
  })  : _storage = storage ?? LocalStorageService(),
        _listing = listing ?? ListingService(),
        _aiService = aiService ?? AiServiceFactory.create(),
        _imagePicker = imagePicker ?? ImagePicker();

  final StorageService _storage;
  final ListingService _listing;
  final AiService _aiService;
  final ImagePicker _imagePicker;

  List<Item> _items = [];
  Item? _currentItem;

  /// Raw bytes of the photo being analyzed. On web there is no app-documents
  /// directory, so the photo lives in memory for the session instead.
  Uint8List? _currentPhotoBytes;

  /// Raw photo bytes for the item currently being analyzed (null until a
  /// photo is picked). Used for display and sharing on web.
  Uint8List? get currentPhotoBytes => _currentPhotoBytes;

  bool _loaded = false;
  bool _isAnalyzing = false;
  int _analysisStep = 0;
  String? _analysisError;

  /// Platforms the user ticked on the Price & Platforms screen.
  final Set<String> selectedPlatforms = {
    Marketplace.facebook.name,
    Marketplace.ebay.name,
  };

  // ----- getters ---------------------------------------------------------

  List<Item> get items => List<Item>.unmodifiable(_items);
  Item? get currentItem => _currentItem;
  bool get isLoaded => _loaded;
  bool get isAnalyzing => _isAnalyzing;
  int get analysisStep => _analysisStep;
  String? get analysisError => _analysisError;
  ListingService get listingService => _listing;

  /// Sum of suggested prices across non-sold items (dashboard summary).
  double get estimatedInventoryValue => _items
      .where((i) => i.status != ListingStatus.sold)
      .fold(0.0, (sum, i) => sum + i.suggestedPrice);

  List<Item> get recentItems => _items.take(10).toList();

  // ----- lifecycle -------------------------------------------------------

  Future<void> init() async {
    _items = await _storage.loadItems();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() => _storage.saveItems(_items);

  // ----- capture → analysis flow -----------------------------------------

  /// Picks a photo from [source], copies it into app documents (so it
  /// survives cache clears), and runs the AI pipeline. Returns the finished
  /// [Item], or null when the user cancelled the picker.
  Future<Item?> pickAndAnalyze(ImageSource source) async {
    final picked = await _imagePicker.pickImage(
      source: source,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (picked == null) return null; // user cancelled

    final bytes = await picked.readAsBytes();
    _currentPhotoBytes = bytes;
    // Web has no app-documents directory: keep the photo in memory and use
    // the picker's blob path for reference only.
    final savedPath =
        kIsWeb ? picked.path : await _copyToDocuments(File(picked.path));

    _currentItem = Item(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      photoPath: savedPath,
      title: 'Analyzing…',
      category: 'Miscellaneous',
      condition: ItemCondition.good,
      priceLow: 0,
      priceHigh: 0,
      suggestedPrice: 0,
      description: '',
    );
    _isAnalyzing = true;
    _analysisStep = 0;
    _analysisError = null;
    notifyListeners();

    try {
      final result = await _runPipelineWithSteps(bytes);
      _currentItem = _currentItem!.copyWith(
        title: result.title,
        category: result.category,
        condition: result.condition,
        priceLow: result.priceLow,
        priceHigh: result.priceHigh,
        suggestedPrice: result.suggestedPrice,
        description: result.description,
        status: ListingStatus.draft,
      );
    } on AiServiceException catch (e) {
      // Live backend failed — fall back to the mock so the demo continues.
      debugPrint('Live AI failed, falling back to mock: $e');
      try {
        final fallback = await MockAiService().analyzeItem(bytes);
        _currentItem = _currentItem!.copyWith(
          title: fallback.title,
          category: fallback.category,
          condition: fallback.condition,
          priceLow: fallback.priceLow,
          priceHigh: fallback.priceHigh,
          suggestedPrice: fallback.suggestedPrice,
          description: fallback.description,
          status: ListingStatus.draft,
        );
        _analysisError = 'Live AI unavailable — showing demo data.';
      } catch (_) {
        _analysisError = 'Could not analyze this photo. Please try again.';
      }
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }

    return _currentItem;
  }

  /// Drives the visible step indicator while the AI call runs.
  Future<AiAnalysisResult> _runPipelineWithSteps(Uint8List photoBytes) async {
    final pending = _aiService.analyzeItem(photoBytes);
    // Walk the visible steps; the real AI result is awaited on the final step
    // so the progress UI feels alive even when the backend is fast.
    for (var i = 0; i < kAnalysisSteps.length; i++) {
      _analysisStep = i;
      notifyListeners();
      if (i == kAnalysisSteps.length - 1) {
        final result = await pending;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return result;
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    // Unreachable: the loop always returns on its final iteration.
    return pending;
  }

  Future<String> _copyToDocuments(File source) async {
    final dir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${dir.path}/photos');
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }
    final ext = source.path.split('.').last.toLowerCase();
    final safeExt = ['jpg', 'jpeg', 'png', 'heic', 'webp'].contains(ext)
        ? ext
        : 'jpg';
    final dest =
        File('${photosDir.path}/${DateTime.now().microsecondsSinceEpoch}.$safeExt');
    await source.copy(dest.path);
    return dest.path;
  }

  // ----- editing the current listing --------------------------------------

  void updateCurrentItem({
    String? title,
    String? category,
    ItemCondition? condition,
    double? priceLow,
    double? priceHigh,
    double? suggestedPrice,
    String? description,
  }) {
    if (_currentItem == null) return;
    _currentItem = _currentItem!.copyWith(
      title: title,
      category: category,
      condition: condition,
      priceLow: priceLow,
      priceHigh: priceHigh,
      suggestedPrice: suggestedPrice,
      description: description,
    );
    notifyListeners();
  }

  void togglePlatform(String name) {
    if (selectedPlatforms.contains(name)) {
      selectedPlatforms.remove(name);
    } else {
      selectedPlatforms.add(name);
    }
    notifyListeners();
  }

  /// Saves the current item into the library (insert or update).
  Future<void> saveCurrentItem({ListingStatus? status}) async {
    final item = _currentItem;
    if (item == null) return;
    final toSave = status == null
        ? item
        : item.copyWith(
            status: status,
            platforms: selectedPlatforms.toList(),
          );
    final index = _items.indexWhere((e) => e.id == toSave.id);
    if (index >= 0) {
      _items[index] = toSave;
    } else {
      _items.insert(0, toSave);
    }
    _currentItem = toSave;
    await _persist();
    notifyListeners();
  }

  /// Opens an existing library item for editing / re-posting.
  void openItem(Item item) {
    _currentItem = item;
    selectedPlatforms
      ..clear()
      ..addAll(item.platforms.isEmpty
          ? [Marketplace.facebook.name, Marketplace.ebay.name]
          : item.platforms);
    notifyListeners();
  }

  void discardCurrentItem() {
    _currentItem = null;
    notifyListeners();
  }

  Future<void> deleteItem(String id) async {
    _items.removeWhere((e) => e.id == id);
    if (_currentItem?.id == id) _currentItem = null;
    await _persist();
    notifyListeners();
  }

  Future<void> markSold(String id) async {
    final index = _items.indexWhere((e) => e.id == id);
    if (index < 0) return;
    _items[index] = _items[index].copyWith(status: ListingStatus.sold);
    await _persist();
    notifyListeners();
  }
}
