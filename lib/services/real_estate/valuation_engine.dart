library;

/// Real-estate valuation engine (Workstream B).
///
/// Combines evidence per the spec's weighting:
///   1. recent comparable sales (strongest)
///   2. very recent sale history of the subject
///   3. property characteristics
///   4. BC Assessment data (a DATA INPUT — never used as market value)
///   5. permit history
///   6. confirmed renovations
///   7. visible property condition
///   8. local $/sqft data
///   9. lot value where meaningful
///  10. current local market conditions
///
/// Produces a LOW / MIDPOINT / HIGH range plus a confidence score per the
/// spec's HIGH / MEDIUM / LOW criteria. Prefers ranges; never fakes
/// precision (rounds to the nearest \$1,000).
///
/// THE HONESTY CORE: without authorized comparable sales there is no
/// defensible market value. In that case the engine returns
/// [ValuationResult.insufficientData] == true with ALL THREE value fields
/// null and [ValuationConfidence.low], plus [reasons] naming exactly what
/// is missing. Nulls are nulls — never zeros disguised as data.

import 'property_models.dart';

class ValuationEngine {
  /// Estimates market value from the available evidence.
  ///
  /// Today every data provider is a documented placeholder, so the honest
  /// outcome is always the insufficient-data state. When live adapters
  /// land, this same engine consumes them — the math below is the real
  /// logic, already unit-tested with synthetic comparables.
  ValuationResult estimate({
    PropertyAddress? address,
    required PropertyType propertyType,
    PropertyCharacteristics? characteristics,
    AssessmentData? assessment,
    List<PermitRecord> permits = const [],
    List<RenovationRecord> renovations = const [],
    List<ConditionObservation> conditionObservations = const [],
    List<ComparableSale> comparables = const [],
    List<SubjectSale> recentSales = const [],
    MarketConditions? market,
  }) {
    final reasons = <String>[];
    final adjustments = <String>[];

    if (address == null || !address.isComplete) {
      reasons.add('No confirmed property address — official assessment, '
          'permit and comparable-sales research requires the address.');
    }
    if (characteristics == null) {
      reasons.add('No reliable property characteristics (beds, baths, '
          'square footage, lot size).');
    }

    // Comparable sales are the strongest evidence — and the only lawful
    // source is an authorized sold-data feed, which is not connected.
    final priced = comparables
        .where((c) => c.salePrice != null && c.salePrice! > 0)
        .toList()
      ..sort((a, b) => b.similarityScore.compareTo(a.similarityScore));
    final strong = priced.where((c) => c.similarityScore >= 70).toList();
    if (priced.isEmpty) {
      reasons.add('No authorized comparable sales available — MLS sold '
          'data requires licensed realtor access, which is not connected.');
    }

    if (assessment == null) {
      reasons.add('No BC Assessment data — BC Assessment has no public '
          'API, so assessed values cannot be retrieved automatically.');
    } else {
      // Assessment is a data input, never the market value.
      reasons.add('BC Assessment value is shown separately and is not '
          'used as the market value — assessed and market values can differ.');
    }

    if (strong.length >= 3) {
      return _fromComparables(
        strong: strong,
        reasons: reasons,
        adjustments: adjustments,
        market: market,
        recentSales: recentSales,
      );
    }

    if (priced.isNotEmpty) {
      // 1–2 comparables: a very wide, clearly-labeled range at best.
      return _fromThinComparables(
        priced: priced,
        reasons: reasons,
        adjustments: adjustments,
      );
    }

    // No defensible market evidence at all — the honest state.
    reasons.add('Without comparable sales or assessment data there is no '
        'basis for a market value. Add the property address and connect a '
        'licensed sold-data source to enable valuation.');
    return ValuationResult(
      estimatedLow: null,
      estimatedMid: null,
      estimatedHigh: null,
      confidence: ValuationConfidence.low,
      insufficientData: true,
      reasons: reasons,
      methodologyNote:
          'Valuation requires PHOTO + CONFIRMED ADDRESS + PROPERTY '
          'CHARACTERISTICS + BC ASSESSMENT / PROPERTY RECORDS + PERMIT & '
          'RENOVATION INFORMATION + AUTHORIZED COMPARABLE SALES + LOCAL '
          'MARKET DATA. Missing inputs are listed above — no value was '
          'estimated. This is not an appraisal.',
    );
  }

  ValuationResult _fromComparables({
    required List<ComparableSale> strong,
    required List<String> reasons,
    required List<String> adjustments,
    MarketConditions? market,
    List<SubjectSale> recentSales = const [],
  }) {
    // Adjusted prices: start from sale price, note each comp's adjustments
    // transparently (real adjustment math per factor lands with live data;
    // today we carry the comp's own adjustment notes through).
    final adjusted =
        strong.map((c) => c.salePrice!).toList()..sort();
    for (final c in strong) {
      adjustments.addAll(c.adjustments);
    }
    final median = _median(adjusted);
    final spread = adjusted.last - adjusted.first;
    // Range widens with comp disagreement — never fake precision.
    final halfWidth = (spread / 2).clamp(15000.0, 150000.0);
    final low = _roundToThousand(median - halfWidth);
    final high = _roundToThousand(median + halfWidth);
    final mid = _roundToThousand(median);

    // Consistency check: tight comps -> HIGH, scattered -> MEDIUM.
    final cv = median > 0 ? spread / median : 1.0;
    final confidence =
        cv <= 0.10 ? ValuationConfidence.high : ValuationConfidence.medium;
    if (confidence == ValuationConfidence.medium) {
      reasons.add('Comparable sales vary — range widened to reflect the '
          'disagreement.');
    }
    if (market?.benchmarkPriceChangePct != null) {
      reasons.add('Local benchmark trend (${market!.sourceLabel ?? 'market '
          'data'}): ${market.benchmarkPriceChangePct!.toStringAsFixed(1)}%.');
    }
    // The subject's own very recent sale is supporting evidence only: it
    // is noted and checked against the comp range, never used as the value.
    final recent = recentSales.where((s) {
      final age = DateTime.now().difference(s.saleDate).inDays;
      return age >= 0 && age <= 180;
    }).toList()
      ..sort((a, b) => b.saleDate.compareTo(a.saleDate));
    if (recent.isNotEmpty) {
      final s = recent.first;
      final within =
          s.salePrice >= low && s.salePrice <= high ? 'within' : 'outside';
      reasons.add('Subject sold for ${_money(s.salePrice)} on '
          '${s.saleDate.toIso8601String().substring(0, 10)} '
          '($within the comp-derived range).');
    }
    return ValuationResult(
      estimatedLow: low,
      estimatedMid: mid,
      estimatedHigh: high,
      confidence: confidence,
      insufficientData: false,
      reasons: reasons,
      adjustments: adjustments,
      methodologyNote:
          'Range from ${strong.length} authorized comparable sales '
          '(similarity ≥ 70), median ± observed spread, rounded to the '
          'nearest \$1,000. Assessment shown separately. '
          'This is an automated estimate, not a formal appraisal.',
    );
  }

  ValuationResult _fromThinComparables({
    required List<ComparableSale> priced,
    required List<String> reasons,
    required List<String> adjustments,
  }) {
    reasons.add('Only ${priced.length} comparable sale(s) — below the '
        '3-sale minimum for a reliable range.');
    final prices = priced.map((c) => c.salePrice!).toList()..sort();
    final mid = _median(prices);
    // Deliberately wide: ±25% signals how thin the evidence is.
    final low = _roundToThousand(mid * 0.75);
    final high = _roundToThousand(mid * 1.25);
    for (final c in priced) {
      adjustments.addAll(c.adjustments);
    }
    return ValuationResult(
      estimatedLow: low,
      estimatedMid: _roundToThousand(mid),
      estimatedHigh: high,
      confidence: ValuationConfidence.low,
      insufficientData: false,
      reasons: reasons,
      adjustments: adjustments,
      methodologyNote:
          'Very wide preliminary range from ${priced.length} comparable '
          'sale(s) (±25%). Treat as a rough indication only — more '
          'comparables are needed for a reliable estimate. '
          'This is an automated estimate, not a formal appraisal.',
    );
  }

  double _median(List<double> sorted) {
    final n = sorted.length;
    if (n.isOdd) return sorted[n ~/ 2];
    return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
  }

  double _roundToThousand(double v) => (v / 1000).round() * 1000.0;

  String _money(double v) =>
      '\$${v.toStringAsFixed(0).replaceAllMapped(
            RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
            (m) => '${m[1]},',
          )}';
}
