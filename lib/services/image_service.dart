import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'ai_logger.dart';

/// Photo prepared for the analysis backend.
class ProcessedImage {
  const ProcessedImage({
    required this.bytes,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.wasRecompressed,
  });

  /// Bytes to upload.
  final Uint8List bytes;

  /// Real MIME type of [bytes] (never a guess — detected or converted).
  final String mimeType;

  final int width;
  final int height;

  /// True when the image was decoded and re-encoded as JPEG
  /// (as opposed to passed through untouched).
  final bool wasRecompressed;
}

/// Normalizes camera/gallery photos before upload (Phase 3):
///
/// - longest side scaled to 1536 px (keeps brand text / labels readable)
/// - JPEG quality 80
/// - EXIF orientation baked in so the photo is never sideways
/// - JPEG/PNG/WEBP decoded properly; anything else (e.g. HEIC, which the
///   pure-Dart decoder cannot read) is passed through with its detected
///   MIME type — the backend converts it via sharp.
///
/// Throws [ImageProcessingException] when the bytes are not a photo at all.
class ImageService {
  static const int maxSide = 1536;
  static const int jpegQuality = 80;

  /// Detects the MIME type from magic bytes. Never trusts extensions.
  static String detectMimeType(Uint8List bytes) {
    if (bytes.length < 12) return 'application/octet-stream';
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    // HEIC/HEIF: 'ftyp' box at offset 4 with an HEIC-family brand.
    if (bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      final brand = String.fromCharCodes(bytes.sublist(8, 12));
      if (brand.startsWith('heic') ||
          brand.startsWith('heix') ||
          brand.startsWith('hevc') ||
          brand.startsWith('heim') ||
          brand.startsWith('heis') ||
          brand.startsWith('mif1')) {
        return 'image/heic';
      }
    }
    return 'application/octet-stream';
  }

  /// Compresses + normalizes [bytes] for upload.
  ProcessedImage process(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw ImageProcessingException('Empty image data.');
    }
    if (bytes.length > 25 * 1024 * 1024) {
      throw ImageProcessingException('Image is too large.');
    }

    final mimeType = detectMimeType(bytes);
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      decoded = null; // undecodable (e.g. HEIC) — handled below
    }
    if (decoded == null) {
      // Not decodable here (e.g. HEIC on some platforms): pass through with
      // the honest MIME type; the backend converts it.
      if (mimeType == 'application/octet-stream') {
        throw ImageProcessingException('File is not a readable photo.');
      }
      AiLogger.requestStarted(inBytes: bytes.length, mimeType: mimeType);
      return ProcessedImage(
        bytes: bytes,
        mimeType: mimeType,
        width: 0,
        height: 0,
        wasRecompressed: false,
      );
    }

    // Bake EXIF orientation so the photo is never sideways/upside-down.
    final oriented = img.bakeOrientation(decoded);

    img.Image resized = oriented;
    final longest = oriented.width > oriented.height
        ? oriented.width
        : oriented.height;
    if (longest > maxSide) {
      final scale = maxSide / longest;
      resized = img.copyResize(
        oriented,
        width: (oriented.width * scale).round(),
        height: (oriented.height * scale).round(),
        interpolation: img.Interpolation.linear,
      );
    }

    final jpeg = img.encodeJpg(resized, quality: jpegQuality);
    AiLogger.imageCompressed(
      inBytes: bytes.length,
      outBytes: jpeg.length,
      width: resized.width,
      height: resized.height,
    );
    return ProcessedImage(
      bytes: Uint8List.fromList(jpeg),
      mimeType: 'image/jpeg',
      width: resized.width,
      height: resized.height,
      wasRecompressed: true,
    );
  }
}

class ImageProcessingException implements Exception {
  ImageProcessingException(this.message);
  final String message;

  @override
  String toString() => 'ImageProcessingException: $message';
}
