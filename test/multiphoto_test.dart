import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:snap2sell/models/ai_analysis_result.dart';
import 'package:snap2sell/models/item.dart';
import 'package:snap2sell/providers/app_state.dart';
import 'package:snap2sell/services/ai_service.dart';

import 'backend_ai_service_test.dart'
    show makeTestJpeg, ninjaIdentification, serviceWith, jsonResponse;

/// AiService that records which entrypoint was used and answers with a fixed
/// listing whose title encodes the photo count it saw.
class _RecordingAiService implements AiService {
  int singleCalls = 0;
  final List<int> multiCallSizes = [];

  AiAnalysisResult _answer(int n) => AiAnalysisResult(
        title: 'Item from $n photo${n == 1 ? '' : 's'}',
        category: 'Miscellaneous',
        condition: ItemCondition.good,
        priceLow: 10,
        priceHigh: 20,
        suggestedPrice: 15,
        description: 'desc',
      );

  @override
  Future<AiAnalysisResult> analyzeItem(Uint8List photoBytes) async {
    singleCalls++;
    return _answer(1);
  }

  @override
  Future<AiAnalysisResult> analyzeItems(List<Uint8List> photos) async {
    multiCallSizes.add(photos.length);
    return _answer(photos.length);
  }
}

/// ImagePicker stub that hands out pre-made files, then reports cancellation.
class _FakeImagePicker extends ImagePicker {
  _FakeImagePicker(this.files);
  final List<File> files;
  int _i = 0;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    if (_i >= files.length) return null;
    return XFile(files[_i++].path);
  }
}

Future<File> _tempJpeg(String name) async {
  final file = File('${Directory.systemTemp.path}/$name.jpg');
  await file.writeAsBytes(makeTestJpeg(w: 64, h: 64));
  return file;
}

void _mockPathProvider() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'getApplicationDocumentsDirectory') {
      final dir = Directory('${Directory.systemTemp.path}/snap2sell-docs');
      await dir.create(recursive: true);
      return dir.path;
    }
    return null;
  });
}

void main() {
  group('multi-photo backend request', () {
    test('analyzeItems posts an images array (no imageBase64 field)',
        () async {
      final photos = [makeTestJpeg(), makeTestJpeg(), makeTestJpeg()];
      final service = serviceWith(MockClient((request) async {
        expect(request.headers['x-app-secret'], 'test-secret');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.containsKey('imageBase64'), isFalse,
            reason: 'multi-photo must use the images array, not imageBase64');
        final images = body['images'] as List<dynamic>;
        expect(images.length, 3);
        expect(images.every((e) => (e as String).isNotEmpty), isTrue);
        return jsonResponse(ninjaIdentification(), 200);
      }));

      final result = await service.analyzeItems(photos);

      expect(result.title, 'Ninja Countertop Blender — Black');
      expect(result.suggestedPrice, 55);
    });

    test('REGRESSION: analyzeItem still posts the single imageBase64 field',
        () async {
      final service = serviceWith(MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.containsKey('images'), isFalse,
            reason: 'single-photo path must not send the images array');
        expect(body['imageBase64'], isNotEmpty);
        return jsonResponse(ninjaIdentification(), 200);
      }));

      final result = await service.analyzeItem(makeTestJpeg());

      expect(result.title, contains('Ninja'));
    });

    test('default analyzeItems falls back to the first photo', () async {
      // MockAiService only implements analyzeItem: the interface default
      // must keep it working for multi-photo callers.
      final service = MockAiService(seed: 1);
      final result = await service.analyzeItems(
          [makeTestJpeg(), makeTestJpeg(), makeTestJpeg()]);
      expect(result.title, isNotEmpty);
    });

    test('low-confidence guidance still fires for multi-photo results',
        () async {
      final id = ninjaIdentification(confidence: 30)
        ..['needs_more_photos'] = true
        ..['recommended_photos'] = ['Take a photo of the front.'];
      final service =
          serviceWith(MockClient((_) async => jsonResponse(id, 200)));

      AiServiceException? err;
      try {
        await service.analyzeItems([makeTestJpeg(), makeTestJpeg()]);
      } on AiServiceException catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      expect(err!.category, AiErrorCategory.lowConfidence);
    });
  });

  group('Item extraPhotoPaths persistence', () {
    test('round-trips through JSON', () {
      final item = Item(
        id: '1',
        photoPath: '/a.jpg',
        title: 't',
        category: 'Furniture',
        condition: ItemCondition.good,
        priceLow: 1,
        priceHigh: 2,
        suggestedPrice: 1.5,
        description: 'd',
        extraPhotoPaths: ['/b.jpg', '/c.jpg'],
      );
      final restored = Item.fromJson(item.toJson());
      expect(restored.extraPhotoPaths, ['/b.jpg', '/c.jpg']);
      expect(restored.photoPath, '/a.jpg');
    });

    test('REGRESSION: items saved before multi-photo get an empty list',
        () {
      final oldJson = {
        'id': '1',
        'photoPath': '/a.jpg',
        'title': 't',
        'category': 'Furniture',
        'condition': 'good',
        'priceLow': 1,
        'priceHigh': 2,
        'suggestedPrice': 1.5,
        'description': 'd',
        'platforms': [],
        'status': 'draft',
        'createdAt': DateTime.now().toIso8601String(),
      };
      final restored = Item.fromJson(oldJson);
      expect(restored.extraPhotoPaths, isEmpty);
    });
  });

  group('AppState multi-photo flow', () {
    test('addPhoto grows the set up to the 5-photo cap', () async {
      _mockPathProvider();
      final files = [
        for (var i = 0; i < 6; i++) await _tempJpeg('multi-add-$i')
      ];
      final ai = _RecordingAiService();
      final appState = AppState(
        aiService: ai,
        imagePicker: _FakeImagePicker(files),
      );

      await appState.analyzePhotoBytes(
        makeTestJpeg(),
        savedPath: '/tmp/main.jpg',
      );
      expect(appState.photoCount, 1);
      expect(appState.canAddMorePhotos, isTrue);

      // Add 4 more -> 5 total. The 6th is refused by the cap.
      for (var i = 0; i < 4; i++) {
        expect(await appState.addPhoto(ImageSource.gallery), isTrue);
      }
      expect(appState.photoCount, 5);
      expect(appState.canAddMorePhotos, isFalse);
      expect(await appState.addPhoto(ImageSource.gallery), isFalse);
      expect(appState.photoCount, 5);
      expect(appState.extraPhotoPaths.length, 4);
    });

    test('removeExtraPhotoAt and moveExtraPhoto reorder the extras',
        () async {
      _mockPathProvider();
      final files = [
        for (var i = 0; i < 3; i++) await _tempJpeg('multi-reorder-$i')
      ];
      final appState = AppState(
        aiService: _RecordingAiService(),
        imagePicker: _FakeImagePicker(files),
      );
      await appState.analyzePhotoBytes(
        makeTestJpeg(),
        savedPath: '/tmp/main.jpg',
      );
      for (var i = 0; i < 3; i++) {
        await appState.addPhoto(ImageSource.gallery);
      }
      final before = List<String>.from(appState.extraPhotoPaths);

      appState.moveExtraPhoto(0, 2);
      final moved = appState.extraPhotoPaths;
      expect(moved[2], before[0]);
      expect(moved.length, 3);

      appState.removeExtraPhotoAt(0);
      expect(appState.extraPhotoPaths.length, 2);
      expect(appState.photoCount, 3);

      // Out-of-range removes are ignored, never crash.
      appState.removeExtraPhotoAt(99);
      appState.removeExtraPhotoAt(-1);
      expect(appState.extraPhotoPaths.length, 2);
    });

    test('reanalyzeWithPhotos sends ALL photos and updates the listing',
        () async {
      _mockPathProvider();
      final files = [
        for (var i = 0; i < 2; i++) await _tempJpeg('multi-reanalyze-$i')
      ];
      final ai = _RecordingAiService();
      final appState = AppState(
        aiService: ai,
        imagePicker: _FakeImagePicker(files),
      );
      await appState.analyzePhotoBytes(
        makeTestJpeg(),
        savedPath: '/tmp/main.jpg',
      );
      expect(ai.singleCalls, 1);
      await appState.addPhoto(ImageSource.gallery);
      await appState.addPhoto(ImageSource.gallery);

      await appState.reanalyzeWithPhotos();

      expect(ai.multiCallSizes, [3]);
      expect(appState.currentItem!.title, 'Item from 3 photos');
      expect(appState.isAnalyzing, isFalse);
      expect(appState.analysisError, isNull);
    });

    test('extras reset when a new photo is analyzed', () async {
      _mockPathProvider();
      final files = [await _tempJpeg('multi-reset-0')];
      final appState = AppState(
        aiService: _RecordingAiService(),
        imagePicker: _FakeImagePicker(files),
      );
      await appState.analyzePhotoBytes(
        makeTestJpeg(),
        savedPath: '/tmp/main.jpg',
      );
      await appState.addPhoto(ImageSource.gallery);
      expect(appState.photoCount, 2);

      await appState.analyzePhotoBytes(
        makeTestJpeg(),
        savedPath: '/tmp/main2.jpg',
      );
      expect(appState.photoCount, 1);
      expect(appState.extraPhotoPaths, isEmpty);
    });
  });
}
