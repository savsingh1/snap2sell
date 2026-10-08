library;

/// App-facing real-estate flow (Workstream B).
///
/// [RealEstateAiService] is a decorator over any [AiService]: it runs the
/// normal analysis first, then — ONLY when [RealEstateDetector] flags the
/// photo as residential real estate — routes the result through the
/// property-valuation flow.
///
/// ADDITIVE GUARANTEE: non-real-estate results pass through byte-identical.
/// The existing product/vehicle scanner (including the Workstream A
/// Apple/Tesla behavior) is untouched — this wrapper never sees, and never
/// alters, those code paths.
///
/// HONESTY: the rewritten real-estate result carries NO prices
/// (0/0/0, tier 3 — "no range available") and an explicit "add the property
/// address" message. The address is NEVER inferred from the photo; it only
/// arrives via [attachAddress], which the user triggers explicitly.

import 'dart:typed_data';

import '../../models/ai_analysis_result.dart';
import '../ai_service.dart';
import 'property_models.dart';
import 'providers.dart';
import 'real_estate_analyzer.dart';
import 'real_estate_detector.dart';

class RealEstateAiService implements AiService {
  RealEstateAiService(
    this._inner, {
    RealEstateProviders providers = RealEstateProviders.defaults,
    RealEstateAnalyzer? analyzer,
  }) : _analyzer = analyzer ?? RealEstateAnalyzer(providers: providers);

  /// Listing category used for real-estate items.
  static const String realEstateCategory = 'Real Estate';

  final AiService _inner;
  final RealEstateAnalyzer _analyzer;

  /// Report for the most recent analysis, when the photo was detected as
  /// real estate. Null for ordinary product listings.
  PropertyValuationReport? _lastReport;
  PropertyValuationReport? get lastPropertyReport => _lastReport;

  AiAnalysisResult? _lastAiResult;
  PropertyType? _lastType;

  @override
  Future<AiAnalysisResult> analyzeItem(Uint8List photoBytes) async {
    final result = await _inner.analyzeItem(photoBytes);
    return _maybeRouteToRealEstate(result);
  }

  @override
  Future<AiAnalysisResult> analyzeItems(List<Uint8List> photos) async {
    final result = await _inner.analyzeItems(photos);
    return _maybeRouteToRealEstate(result);
  }

  Future<AiAnalysisResult> _maybeRouteToRealEstate(
      AiAnalysisResult result) async {
    final type = RealEstateDetector.detectFromResult(result);
    if (type == null) {
      // Not real estate: pass through EXACTLY as the inner service made it.
      _lastReport = null;
      _lastAiResult = null;
      _lastType = null;
      return result;
    }
    _lastAiResult = result;
    _lastType = type;
    _lastReport = await _analyzer.analyze(
      aiResult: result,
      propertyType: type,
    );
    return _toRealEstateResult(result, type, _lastReport!);
  }

  /// Confirms the property address (user-entered — never inferred) and
  /// re-runs the valuation with it. Returns the refreshed listing draft so
  /// the UI can update the item.
  Future<AiAnalysisResult> attachAddress(PropertyAddress address) async {
    final aiResult = _lastAiResult;
    final type = _lastType;
    if (aiResult == null || type == null || !address.isComplete) {
      throw ArgumentError(
          'attachAddress needs a detected property and a complete address.');
    }
    _lastReport = await _analyzer.analyze(
      aiResult: aiResult,
      propertyType: type,
      address: address,
    );
    return _toRealEstateResult(aiResult, type, _lastReport!);
  }

  /// Drops the stashed report (e.g. when the user discards the item or
  /// opens a saved non-real-estate listing).
  void clearReport() {
    _lastReport = null;
    _lastAiResult = null;
    _lastType = null;
  }

  AiAnalysisResult _toRealEstateResult(
    AiAnalysisResult result,
    PropertyType type,
    PropertyValuationReport report,
  ) {
    final baseTitle =
        result.title.trim().isEmpty ? type.label : result.title.trim();
    final observations = report.record.conditionObservations
        .map((o) => o.observation)
        .join(' ');
    final description = StringBuffer(report.nextStepMessage);
    if (observations.isNotEmpty) {
      description.write('\n\nObserved from photo: $observations');
    }
    description.write(
        '\n\nThis is an automated estimate, not a formal appraisal. '
        'No market value is shown until authorized comparable-sales data '
        'is available.');
    return AiAnalysisResult(
      title: '$baseTitle — property valuation',
      category: realEstateCategory,
      condition: result.condition,
      priceLow: 0,
      priceHigh: 0,
      suggestedPrice: 0,
      description: description.toString(),
      // 'property': real-estate identification level (distinct from the
      // product 'exact' / 'product_family' levels). Prices are tier 3 —
      // no range available, never invented.
      identificationLevel: 'property',
      pricingTier: 3,
    );
  }
}
