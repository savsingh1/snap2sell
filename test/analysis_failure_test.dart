import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:snap2sell/models/ai_analysis_result.dart';
import 'package:snap2sell/providers/app_state.dart';
import 'package:snap2sell/services/ai_service.dart';

/// AiService that always fails, simulating a dead backend / bad key / no net.
class _FailingAiService implements AiService {
  @override
  Future<AiAnalysisResult> analyzeItem(Uint8List photoBytes) async {
    throw AiServiceException('Vision API returned HTTP 500: boom');
  }
}

void main() {
  group('Analysis failure produces no fake listing', () {
    test('photo preserved, placeholders cleared, error surfaced', () async {
      final appState = AppState(aiService: _FailingAiService());

      final item = await appState.analyzePhotoBytes(
        Uint8List.fromList([1, 2, 3]),
        savedPath: '/tmp/wallet.jpg',
      );

      expect(item, isNotNull);
      // Photo survives the failure.
      expect(item!.photoPath, '/tmp/wallet.jpg');
      expect(appState.currentPhotoBytes, isNotNull);
      // No invented listing content.
      expect(item.title, '');
      expect(item.description, '');
      expect(item.priceLow, 0);
      expect(item.priceHigh, 0);
      expect(item.suggestedPrice, 0);
      // The reason is surfaced for the UI banner.
      expect(appState.analysisError, contains('Could not analyze'));
      expect(appState.analysisError, contains('500'));
      expect(appState.isAnalyzing, isFalse);
    });

    test('user-entered details survive a failed retry', () async {
      final appState = AppState(aiService: _FailingAiService());
      await appState.analyzePhotoBytes(
        Uint8List.fromList([1, 2, 3]),
        savedPath: '/tmp/wallet.jpg',
      );

      // User types a title manually, then retries and it fails again.
      appState.updateCurrentItem(title: 'My real wallet');
      appState.clearAnalysisError();
      await appState.retryAnalysis();

      expect(appState.currentItem!.title, 'My real wallet');
      expect(appState.currentItem!.photoPath, '/tmp/wallet.jpg');
      expect(appState.analysisError, isNotNull);
    });

    test('clearAnalysisError dismisses the banner for manual entry', () async {
      final appState = AppState(aiService: _FailingAiService());
      await appState.analyzePhotoBytes(
        Uint8List.fromList([1, 2, 3]),
        savedPath: '/tmp/wallet.jpg',
      );
      expect(appState.analysisError, isNotNull);

      appState.clearAnalysisError();
      expect(appState.analysisError, isNull);
      // Item (with photo) is still there for manual entry.
      expect(appState.currentItem, isNotNull);
    });
  });
}
