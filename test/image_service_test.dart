import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snap2sell/services/image_service.dart';

Uint8List makeJpeg(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(200, 150, 100));
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

Uint8List makePng(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(100, 150, 200));
  return Uint8List.fromList(img.encodePng(image));
}

/// Minimal fake HEIC: 'ftyp' box with an heic brand. Not decodable by the
/// pure-Dart codec — must pass through with an honest MIME type.
Uint8List makeFakeHeic() {
  final bytes = Uint8List(32);
  bytes[4] = 0x66; // f
  bytes[5] = 0x74; // t
  bytes[6] = 0x79; // y
  bytes[7] = 0x70; // p
  bytes[8] = 0x68; // h
  bytes[9] = 0x65; // e
  bytes[10] = 0x69; // i
  bytes[11] = 0x63; // c
  return bytes;
}

void main() {
  final service = ImageService();

  group('ImageService', () {
    test('large camera photo is scaled to 1536 on the longest side', () {
      final processed = service.process(makeJpeg(3000, 2000));

      expect(processed.width, 1536);
      expect(processed.height, 1024);
      expect(processed.mimeType, 'image/jpeg');
      expect(processed.wasRecompressed, isTrue);
      // Compressed output is much smaller than a 6MP q95 source.
      expect(processed.bytes.length, lessThan(400 * 1024));
    });

    test('small photo is not upscaled', () {
      final processed = service.process(makeJpeg(800, 600));

      expect(processed.width, 800);
      expect(processed.height, 600);
      expect(processed.mimeType, 'image/jpeg');
    });

    test('portrait photo: height is the constrained side', () {
      final processed = service.process(makeJpeg(2000, 3000));

      expect(processed.height, 1536);
      expect(processed.width, 1024);
    });

    test('PNG is converted to JPEG with the honest MIME type', () {
      final processed = service.process(makePng(800, 600));

      expect(processed.mimeType, 'image/jpeg');
      expect(processed.wasRecompressed, isTrue);
      // JPEG magic bytes, not PNG.
      expect(processed.bytes[0], 0xFF);
      expect(processed.bytes[1], 0xD8);
    });

    test('HEIC passes through with image/heic (backend converts)', () {
      final processed = service.process(makeFakeHeic());

      expect(processed.mimeType, 'image/heic');
      expect(processed.wasRecompressed, isFalse);
    });

    test('garbage bytes throw a readable error', () {
      expect(
        () => service.process(Uint8List.fromList(List.filled(64, 7))),
        throwsA(isA<ImageProcessingException>()),
      );
    });

    test('empty bytes throw', () {
      expect(
        () => service.process(Uint8List(0)),
        throwsA(isA<ImageProcessingException>()),
      );
    });

    group('detectMimeType', () {
      test('jpeg', () {
        expect(ImageService.detectMimeType(makeJpeg(8, 8)), 'image/jpeg');
      });
      test('png', () {
        expect(ImageService.detectMimeType(makePng(8, 8)), 'image/png');
      });
      test('heic', () {
        expect(ImageService.detectMimeType(makeFakeHeic()), 'image/heic');
      });
      test('unknown', () {
        expect(
          ImageService.detectMimeType(Uint8List.fromList(List.filled(32, 1))),
          'application/octet-stream',
        );
      });
    });
  });
}
