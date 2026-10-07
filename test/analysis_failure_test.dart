import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snap2sell/models/ai_analysis_result.dart';
import 'package:snap2sell/providers/app_state.dart';
import 'package:snap2sell/services/ai_service.dart';

/// AiService that always fails, simulating a dead backend / no network.
class _FailingAiService implements AiService {
  @override
  Future<AiAnalysisResult> analyzeItem(Uint8List photoBytes) async {
    throw AiServiceException('Backend exploded.', category: AiErrorCategory.model);
  }
}

/// A real (tiny) JPEG so the image pipeline runs before the AI service.
Uint8List realPhotoBytes() {
  final image = img.Image(width: 64, height: 64);
  img.fill(image, color: img.ColorRgb8(200, 150, 100));
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

void main() {
  group('Analysis failure produces no fake listing', () {
    test('photo preserved, placeholders cleared, friendly error surfaced',
        () async {
      final appState = AppState(aiService: _FailingAiService());

      final item = await appState.analyzePhotoBytes(
        realPhotoBytes(),
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
      // The UI gets a friendly message — never technical details.
      expect(appState.analysisError, isNotNull);
      expect(appState.analysisError, isNot(contains('Exception')));
      expect(appState.analysisError, isNot(contains('http')));
      expect(appState.analysisError, contains("couldn't analyze"));
      expect(appState.isAnalyzing, isFalse);
    });

    test('user-entered details survive a failed retry', () async {
      final appState = AppState(aiService: _FailingAiService());
      await appState.analyzePhotoBytes(
        realPhotoBytes(),
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
        realPhotoBytes(),
        savedPath: '/tmp/wallet.jpg',
      );
      expect(appState.analysisError, isNotNull);

      appState.clearAnalysisError();
      expect(appState.analysisError, isNull);
      // Item (with photo) is still there for manual entry.
      expect(appState.currentItem, isNotNull);
    });

    test('unreadable bytes surface the bad-photo message', () async {
      final appState = AppState(aiService: _FailingAiService());
      await appState.analyzePhotoBytes(
        Uint8List.fromList(List.filled(64, 7)),
        savedPath: '/tmp/bad.bin',
      );

      expect(appState.analysisError, contains('clearer photo'));
      expect(appState.currentItem!.photoPath, '/tmp/bad.bin');
    });
  });
}
