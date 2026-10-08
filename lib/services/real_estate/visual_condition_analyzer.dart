library;

/// Gemini visual-condition analysis for property photos (Workstream B).
///
/// WHAT IS WIRED TODAY (WORKING LIVE DATA): the existing Snap2Sell
/// analysis backend already runs Gemini on the photo. [PhotoConditionAnalyzer]
/// converts that backend output (condition grade + short description) into
/// labeled [ConditionObservation]s. Every observation is labeled
/// OBSERVED FROM PHOTO — visual only, never a renovation year, never a fact
/// about permits or value.
///
/// WHAT IS PLACEHOLDER / FUTURE INTEGRATION: the full interior/exterior
/// condition checklist (roof, windows, siding, kitchen, baths, flooring,
/// …) needs the dedicated real-estate vision prompt. That prompt exists in
/// the repo (functions/analyze-product REAL_ESTATE_PROMPT) but is
/// UNDEPLOYED, so the checklist is not available yet. Until it is, the
/// analyzer says exactly what the current backend observed and nothing more.

import '../../models/ai_analysis_result.dart';
import 'property_models.dart';

/// Visual condition observations from a property photo.
abstract class VisualConditionAnalyzer {
  /// Returns observations labeled OBSERVED FROM PHOTO. Never invents
  /// renovation years, permit facts, or values.
  List<ConditionObservation> analyze(AiAnalysisResult result);
}

/// Uses the live backend's existing product-identification output.
///
/// Honesty guards:
/// - Only repeats what the backend described; sentences carrying a
///   four-digit year are dropped (a photo cannot prove "renovated in 2019").
/// - Visual-appearance sentences ("appears…", "looks…", "visible…") are
///   kept verbatim and labeled OBSERVED FROM PHOTO.
/// - The overall condition grade becomes one "General" observation.
class PhotoConditionAnalyzer implements VisualConditionAnalyzer {
  /// Sentences containing a 4-digit year are never repeated as fact —
  /// the photo cannot prove when a renovation happened.
  static final RegExp _yearPattern = RegExp(r'\b(19|20)\d{2}\b');

  /// Visual-appearance cues worth surfacing as observations.
  static final RegExp _visualCue = RegExp(
    r'\b(appear|appears|look|looks|visible|visibly|seem|seems|show|shows|'
    r'updated|renovated|newer|older|maintained|worn|damaged|fresh|modern|'
    r'dated|original)\b',
    caseSensitive: false,
  );

  /// Rough area detection so observations land under a sensible heading.
  static final Map<String, RegExp> _areaPatterns = {
    'Kitchen': RegExp(r'\bkitchen\b', caseSensitive: false),
    'Bathroom': RegExp(r'\bbath(room)?\b', caseSensitive: false),
    'Roof': RegExp(r'\broof\b', caseSensitive: false),
    'Exterior': RegExp(
        r'\b(exterior|siding|facade|front|landscaping|yard|driveway|garage|deck|patio)\b',
        caseSensitive: false),
    'Interior': RegExp(
        r'\b(interior|flooring|walls|ceiling|cabinet|countertop|appliance)\b',
        caseSensitive: false),
    'Basement': RegExp(r'\bbasement\b', caseSensitive: false),
  };

  @override
  List<ConditionObservation> analyze(AiAnalysisResult result) {
    final observations = <ConditionObservation>[];

    // Overall condition grade from the backend — a visual assessment.
    final conditionLabel = _conditionLabel(result.condition.name);
    observations.add(ConditionObservation(
      area: 'General',
      observation: 'Overall visible condition: $conditionLabel.',
    ));

    // Surface the backend's own visual-appearance sentences, verbatim,
    // minus anything carrying a year claim.
    for (final sentence in _sentences(result.description)) {
      final trimmed = sentence.trim();
      if (trimmed.isEmpty) continue;
      if (_yearPattern.hasMatch(trimmed)) continue; // never launder a year
      if (!_visualCue.hasMatch(trimmed)) continue;
      observations.add(ConditionObservation(
        area: _areaOf(trimmed),
        observation: _ensurePeriod(trimmed),
      ));
      if (observations.length >= 9) break; // overall + up to 8 specifics
    }

    return observations;
  }

  List<String> _sentences(String text) {
    final cleaned = text
        .replaceAll('(AI estimate — please confirm details before listing.)',
            '')
        .trim();
    return cleaned
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.length > 12)
        .toList();
  }

  String _areaOf(String sentence) {
    for (final entry in _areaPatterns.entries) {
      if (entry.value.hasMatch(sentence)) return entry.key;
    }
    return 'General';
  }

  String _ensurePeriod(String s) =>
      s.endsWith('.') || s.endsWith('!') ? s : '$s.';

  String _conditionLabel(String name) => switch (name) {
        'likeNew' => 'Like New',
        'excellent' => 'Excellent',
        'good' => 'Good',
        'fair' => 'Fair',
        'poor' => 'Poor',
        _ => 'Good',
      };
}
