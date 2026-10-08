library;

/// Real-estate analysis orchestrator (Workstream B).
///
/// Pipeline (spec):
///   PHOTO -> REAL_ESTATE detected -> [address?] -> providers ->
///   visual-condition analyzer -> valuation engine -> report
///
/// The analyzer never fails because a source is unavailable: each provider
/// degrades to its honest "unavailable" state, confidence drops
/// accordingly, and the report says exactly what is missing.

import '../../models/ai_analysis_result.dart';
import 'property_models.dart';
import 'providers.dart';
import 'valuation_engine.dart';
import 'visual_condition_analyzer.dart';

class RealEstateAnalyzer {
  RealEstateAnalyzer({
    this.providers = RealEstateProviders.defaults,
    VisualConditionAnalyzer? visualAnalyzer,
    ValuationEngine? engine,
  })  : _visualAnalyzer = visualAnalyzer ?? PhotoConditionAnalyzer(),
        _engine = engine ?? ValuationEngine();

  final RealEstateProviders providers;
  final VisualConditionAnalyzer _visualAnalyzer;
  final ValuationEngine _engine;

  /// Builds the full property report.
  ///
  /// - [aiResult]: the backend's analysis of the property photo.
  /// - [propertyType]: from [RealEstateDetector].
  /// - [address]: user-confirmed address (null = photo-only mode).
  /// - [userCharacteristics]: owner-entered details, labeled
  ///   CONFIRMED BY USER.
  /// - [userRenovations]: owner-reported renovations, labeled
  ///   CONFIRMED BY USER — never merged with photo observations.
  /// - [subjectSales]: the subject's own sale history, if known (empty
  ///   today — no lawful source is connected).
  Future<PropertyValuationReport> analyze({
    required AiAnalysisResult aiResult,
    required PropertyType propertyType,
    PropertyAddress? address,
    PropertyCharacteristics? userCharacteristics,
    List<RenovationRecord> userRenovations = const [],
    List<SubjectSale> subjectSales = const [],
  }) async {
    final confirmedAddress =
        address != null && address.isComplete ? address : null;

    // Providers need an address; without one they are skipped (not failed).
    final assessmentR = confirmedAddress == null
        ? null
        : await providers.assessment.getAssessment(confirmedAddress);
    final detailsR = confirmedAddress == null
        ? null
        : await providers.details.getDetails(confirmedAddress);
    final permitsR = confirmedAddress == null
        ? null
        : await providers.permits.getPermits(confirmedAddress);
    final compsR = confirmedAddress == null
        ? null
        : await providers.comparables.getComparables(
            address: confirmedAddress,
            propertyType: propertyType,
            characteristics:
                userCharacteristics ?? detailsR?.data,
          );
    final marketR = confirmedAddress == null
        ? null
        : await providers.market.getMarketConditions(
            city: confirmedAddress.city,
            province: confirmedAddress.province,
          );

    // Visual condition: WORKING LIVE DATA via the existing backend.
    final observations = _visualAnalyzer.analyze(aiResult);

    // Renovation intelligence: evidence labels never merged.
    final renovations = <RenovationRecord>[
      ...userRenovations,
      // Photo-suspected renovations stay as labeled observations, not
      // records — only confirmed items become RenovationRecords.
    ];

    final valuation = _engine.estimate(
      address: confirmedAddress,
      propertyType: propertyType,
      characteristics: userCharacteristics ?? detailsR?.data,
      assessment: assessmentR?.data,
      permits: permitsR?.data ?? const [],
      renovations: renovations,
      conditionObservations: observations,
      comparables: compsR?.data ?? const [],
      recentSales: subjectSales,
      market: marketR?.data,
    );

    final dataSources = <DataSourceNote>[
      const DataSourceNote(
        sourceName: 'Photo analysis (Gemini via Snap2Sell backend)',
        isLive: true,
        detail: 'Live data — visual observations only, labeled '
            'OBSERVED FROM PHOTO.',
      ),
      if (assessmentR != null) assessmentR.toNote(),
      if (detailsR != null) detailsR.toNote(),
      if (permitsR != null) permitsR.toNote(),
      if (compsR != null) compsR.toNote(),
      if (marketR != null) marketR.toNote(),
    ];

    final record = PropertyRecord(
      address: confirmedAddress,
      propertyType: propertyType,
      characteristics: userCharacteristics ?? detailsR?.data,
      assessment: assessmentR?.data,
      permitHistory: permitsR?.data ?? const [],
      knownRenovations: renovations,
      conditionObservations: observations,
      recentSales: subjectSales,
      comparableSales: compsR?.data ?? const [],
      marketConditions: marketR?.data,
      valuation: valuation,
    );

    return PropertyValuationReport(
      record: record,
      generatedAt: DateTime.now(),
      addressConfirmed: confirmedAddress != null,
      dataSources: dataSources,
      nextStepMessage: confirmedAddress != null
          ? 'Address confirmed. Valuation uses every connected source; '
              'see details for what is still unavailable.'
          : 'Home detected. Add the property address for a full valuation.',
    );
  }
}
