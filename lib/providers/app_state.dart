import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_analysis_result.dart';
import '../models/item.dart';
import '../services/ai_logger.dart';
import '../services/ai_service.dart';
import '../services/image_service.dart';
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
    ImageService? imageService,
  })  : _storage = storage ?? LocalStorageService(),
        _listing = listing ?? ListingService(),
        _aiService = aiService ?? AiServiceFactory.create(),
        _imagePicker = imagePicker ?? ImagePicker(),
        _imageService = imageService ?? ImageService();

  final StorageService _storage;
  final ListingService _listing;
  final AiService _aiService;
  final ImagePicker _imagePicker;
  final ImageService _imageService;

  List<Item> _items = [];
  Item? _currentItem;

  /// Raw bytes of the photo being analyzed. On web there is no app-documents
  /// directory, so the photo lives in memory for the session instead.
  Uint8List? _currentPhotoBytes;

  /// Extra photos added from the review screen (up to [maxPhotosPerListing]
  /// total including the main photo). Bytes may be null until lazy-loaded
  /// from [_extraPhotoPaths] on demand.
  final List<Uint8List?> _extraPhotoBytes = [];
  final List<String> _extraPhotoPaths = [];

  /// Cap on photos per listing (main + extras).
  static const int maxPhotosPerListing = 5;

  /// Raw photo bytes for the item currently being analyzed (null until a
  /// photo is picked). Used for display and sharing on web.
  Uint8List? get currentPhotoBytes => _currentPhotoBytes;

  /// Paths of the extra photos (in addition to the main [Item.photoPath]).
  List<String> get extraPhotoPaths => List<String>.unmodifiable(_extraPhotoPaths);

  /// Total photo count for the current listing (main + extras).
  int get photoCount => 1 + _extraPhotoPaths.length;

  bool get canAddMorePhotos => photoCount < maxPhotosPerListing;

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
    await _loadPayoutPrefs();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() => _storage.saveItems(_items);

  // ----- payout preferences ------------------------------------------------
  // How the seller wants to be paid. Sales happen on the marketplaces, so
  // this is preference info (e-transfer details, notes), not payment
  // processing — Snap2Sell never touches the money.

  static const String _prefsEmailKey = 'snap2sell_payout_email';
  static const String _prefsPhoneKey = 'snap2sell_payout_phone';
  static const String _prefsNoteKey = 'snap2sell_payout_note';

  String _payoutEmail = '';
  String _payoutPhone = '';
  String _payoutNote = '';

  String get payoutEmail => _payoutEmail;
  String get payoutPhone => _payoutPhone;
  String get payoutNote => _payoutNote;

  bool get hasPayoutPrefs =>
      _payoutEmail.isNotEmpty ||
      _payoutPhone.isNotEmpty ||
      _payoutNote.isNotEmpty;

  Future<void> _loadPayoutPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _payoutEmail = prefs.getString(_prefsEmailKey) ?? '';
    _payoutPhone = prefs.getString(_prefsPhoneKey) ?? '';
    _payoutNote = prefs.getString(_prefsNoteKey) ?? '';
  }

  Future<void> savePayoutPrefs({
    required String email,
    required String phone,
    required String note,
  }) async {
    _payoutEmail = email.trim();
    _payoutPhone = phone.trim();
    _payoutNote = note.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsEmailKey, _payoutEmail);
    await prefs.setString(_prefsPhoneKey, _payoutPhone);
    await prefs.setString(_prefsNoteKey, _payoutNote);
    notifyListeners();
  }

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
    // Web has no app-documents directory: keep the photo in memory and use
    // the picker's blob path for reference only.
    final savedPath =
        kIsWeb ? picked.path : await _copyToDocuments(File(picked.path));

    return analyzePhotoBytes(bytes, savedPath: savedPath);
  }

  /// Runs the AI pipeline on raw photo [bytes]. The photo is compressed and
  /// normalized first (see [ImageService]), then sent to the backend.
  /// Separated from [pickAndAnalyze] so the analysis/failure path is
  /// unit-testable without the image picker or filesystem.
  @visibleForTesting
  Future<Item?> analyzePhotoBytes(
    Uint8List bytes, {
    required String savedPath,
  }) async {
    _currentPhotoBytes = bytes;
    // A fresh analysis starts a fresh photo set: extras from any previous
    // listing are dropped.
    _extraPhotoBytes.clear();
    _extraPhotoPaths.clear();
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
      // Phase 3: normalize the photo (EXIF orientation, longest side 1536,
      // JPEG q80) so giant camera images never break the upload and the
      // backend always gets a clean, honest MIME type.
      final processed = _imageService.process(bytes);
      final result = await _runPipelineWithSteps(processed.bytes);
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
    } on ImageProcessingException {
      _handleAnalysisFailure(AiServiceException(
        'Unreadable photo.',
        category: AiErrorCategory.badImage,
      ));
    } on AiServiceException catch (e) {
      // Live backend failed — never invent a listing. Keep the photo and any
      // user-entered details, clear AI placeholders, and surface a friendly,
      // non-technical reason so the user can retry or enter details manually.
      _handleAnalysisFailure(e);
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }

    return _currentItem;
  }

  /// Re-runs AI analysis on the current photo, preserving anything the user
  /// has typed. Called from the "Retry analysis" button after a failure.
  Future<void> retryAnalysis() async {
    final bytes = _currentPhotoBytes;
    if (bytes == null || _currentItem == null || _isAnalyzing) return;
    _isAnalyzing = true;
    _analysisStep = 0;
    _analysisError = null;
    notifyListeners();
    try {
      // Compress the original photo again (same as the first attempt).
      final processed = _imageService.process(bytes);
      final result = await _runPipelineWithSteps(processed.bytes);
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
    } on ImageProcessingException {
      _handleAnalysisFailure(AiServiceException(
        'Unreadable photo.',
        category: AiErrorCategory.badImage,
      ));
    } on AiServiceException catch (e) {
      _handleAnalysisFailure(e);
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }
  }

  /// Dismisses the analysis error banner so the user can enter details
  /// manually. The photo and any typed values are preserved.
  void clearAnalysisError() {
    _analysisError = null;
    notifyListeners();
  }

  // ----- multi-photo ------------------------------------------------------
  // Optional addition: after the first photo is analyzed, the user can add
  // up to 4 more photos from the review screen and re-run the analysis on
  // all of them. The single-photo capture flow above is unchanged.

  /// Adds one more photo to the current listing from [source]. Returns false
  /// when the user cancelled or the 5-photo cap is reached.
  Future<bool> addPhoto(ImageSource source) async {
    if (!canAddMorePhotos || _currentItem == null) return false;
    final picked = await _imagePicker.pickImage(
      source: source,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (picked == null) return false; // user cancelled
    final bytes = await picked.readAsBytes();
    final savedPath =
        kIsWeb ? picked.path : await _copyToDocuments(File(picked.path));
    _extraPhotoBytes.add(bytes);
    _extraPhotoPaths.add(savedPath);
    notifyListeners();
    return true;
  }

  /// Removes an extra photo (index into the extras, not counting the main
  /// photo). The main photo itself cannot be removed.
  void removeExtraPhotoAt(int index) {
    if (index < 0 || index >= _extraPhotoPaths.length) return;
    _extraPhotoBytes.removeAt(index);
    _extraPhotoPaths.removeAt(index);
    notifyListeners();
  }

  /// Reorders extra photos (used by drag-reorder in the thumbnail strip).
  void moveExtraPhoto(int from, int to) {
    if (from < 0 ||
        from >= _extraPhotoPaths.length ||
        to < 0 ||
        to >= _extraPhotoPaths.length) {
      return;
    }
    final path = _extraPhotoPaths.removeAt(from);
    final bytes = _extraPhotoBytes.removeAt(from);
    _extraPhotoPaths.insert(to, path);
    _extraPhotoBytes.insert(to, bytes);
    notifyListeners();
  }

  /// Photo bytes for every photo in the listing, main first. Extras are
  /// lazy-loaded from disk when their in-memory bytes are unavailable
  /// (e.g. after reopening a saved listing).
  Future<List<Uint8List>> _gatherAllPhotoBytes() async {
    final out = <Uint8List>[];
    var main = _currentPhotoBytes;
    if (main == null && !kIsWeb && _currentItem != null) {
      try {
        main = await File(_currentItem!.photoPath).readAsBytes();
        _currentPhotoBytes = main;
      } catch (_) {
        // leave null — the photo may genuinely be gone
      }
    }
    if (main != null) out.add(main);
    for (var i = 0; i < _extraPhotoPaths.length; i++) {
      var b = _extraPhotoBytes[i];
      if (b == null && !kIsWeb) {
        try {
          b = await File(_extraPhotoPaths[i]).readAsBytes();
          _extraPhotoBytes[i] = b;
        } catch (_) {
          // skip unreadable extras
        }
      }
      if (b != null && b.isNotEmpty) out.add(b);
    }
    return out;
  }

  /// Re-runs AI analysis using ALL photos of the current listing. Called
  /// from the review screen after the user adds photos. Anything the user
  /// typed is preserved, exactly like [retryAnalysis].
  Future<void> reanalyzeWithPhotos() async {
    if (_currentItem == null || _isAnalyzing) return;
    final photos = await _gatherAllPhotoBytes();
    if (photos.isEmpty) return;
    _isAnalyzing = true;
    _analysisStep = 0;
    _analysisError = null;
    notifyListeners();
    try {
      final processed =
          photos.map((p) => _imageService.process(p).bytes).toList();
      final result = await _runMultiPipelineWithSteps(processed);
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
    } on ImageProcessingException {
      _handleAnalysisFailure(AiServiceException(
        'Unreadable photo.',
        category: AiErrorCategory.badImage,
      ));
    } on AiServiceException catch (e) {
      _handleAnalysisFailure(e);
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }
  }

  /// Multi-photo twin of [_runPipelineWithSteps]: same animated steps, but
  /// calls [AiService.analyzeItems]. The per-photo processing already
  /// happened, so the cap here covers the backend round trip for up to 5
  /// photos (longer than the single-photo cap).
  Future<AiAnalysisResult> _runMultiPipelineWithSteps(
      List<Uint8List> photoBytesList) async {
    final pending = _aiService
        .analyzeItems(photoBytesList)
        .timeout(const Duration(seconds: 150), onTimeout: () {
      throw AiServiceException(
        'The AI service is taking too long to respond. '
        'Please check your connection and try again.',
      );
    });
    unawaited(pending.then<void>((_) {}, onError: (_) {}));
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
    return pending;
  }

  /// Failure path shared by [pickAndAnalyze] and [retryAnalysis]: the photo
  /// and user-entered details survive, AI placeholders are cleared, and no
  /// demo/fake listing is ever generated.
  ///
  /// SECURITY: only [AiServiceException.friendlyMessage] reaches the UI.
  /// Raw error text (which could contain URLs or technical details) is
  /// logged internally via [AiLogger] and never shown to the user.
  void _handleAnalysisFailure(AiServiceException e) {
    AiLogger.failure(
      category: e.category,
      durationMs: 0,
      attempts: 0,
      detail: 'ui-surfaced',
    );
    final currentTitle = _currentItem?.title;
    _currentItem = _currentItem?.copyWith(
      title: (currentTitle == null || currentTitle == 'Analyzing…')
          ? ''
          : currentTitle,
      description: '',
      priceLow: 0,
      priceHigh: 0,
      suggestedPrice: 0,
      status: ListingStatus.draft,
    );
    _analysisError = e.friendlyMessage;
  }

  /// Drives the visible step indicator while the AI call runs.
  Future<AiAnalysisResult> _runPipelineWithSteps(Uint8List photoBytes) async {
    // Overall cap: the model fallback chain can otherwise grind through
    // per-model timeouts for ~3 minutes on a bad day. Fail fast with the
    // honest error path (retry / manual entry) instead of spinning forever.
    final pending =
        _aiService.analyzeItem(photoBytes).timeout(const Duration(seconds: 75),
            onTimeout: () {
      throw AiServiceException(
        'The AI service is taking too long to respond. '
        'Please check your connection and try again.',
      );
    });
    // Guard: if the AI fails fast, the error would otherwise sit unhandled
    // while the step animation plays. This marks it handled; the await
    // below still receives the same outcome.
    unawaited(pending.then<void>((_) {}, onError: (_) {}));
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
    final withPhotos =
        item.copyWith(extraPhotoPaths: List<String>.from(_extraPhotoPaths));
    final toSave = status == null
        ? withPhotos
        : withPhotos.copyWith(
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
    // Restore extra photos; bytes lazy-load from disk on demand.
    _extraPhotoPaths
      ..clear()
      ..addAll(item.extraPhotoPaths);
    _extraPhotoBytes
      ..clear()
      ..addAll(List<Uint8List?>.filled(item.extraPhotoPaths.length, null));
    _currentPhotoBytes = null;
    selectedPlatforms
      ..clear()
      ..addAll(item.platforms.isEmpty
          ? [Marketplace.facebook.name, Marketplace.ebay.name]
          : item.platforms);
    notifyListeners();
  }

  void discardCurrentItem() {
    _currentItem = null;
    _currentPhotoBytes = null;
    _extraPhotoBytes.clear();
    _extraPhotoPaths.clear();
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
