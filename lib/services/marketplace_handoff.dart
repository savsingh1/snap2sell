import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/item.dart';

/// A fully-built, ready-to-execute Facebook Marketplace handoff.
///
/// Meta has NO public API for posting consumer Marketplace listings, so
/// the fastest honest route is a packaged handoff: Snap2Sell prepares
/// everything, then the seller finishes inside Facebook's own create
/// flow. This object is the pure, testable description of that handoff;
/// [MarketplaceHandoffService.execute] carries it out.
class HandoffIntent {
  const HandoffIntent({
    required this.clipboardText,
    required this.createListingUri,
    required this.photoPaths,
    required this.designedSteps,
  });

  /// The single pre-formatted listing text (title, price, condition,
  /// description) copied to the clipboard in one go.
  final String clipboardText;

  /// Facebook Marketplace's official create-listing flow.
  final Uri createListingUri;

  /// All listing photos (main photo first, then extras) to share.
  final List<String> photoPaths;

  /// The designed user steps, in order, for this handoff. Used by the
  /// hub UI to tell the seller exactly what will happen.
  final List<String> designedSteps;
}

/// One-tap Facebook Marketplace handoff.
///
/// A single button press performs, in order:
///   (a) copy the pre-formatted listing text to the clipboard,
///   (b) open the OS share sheet with all listing photos,
///   (c) deep-link to facebook.com/marketplace/create/item.
///
/// DESIGNED tap count (on-device measurement still pending): 2 taps in
/// Snap2Sell + share sheet (the button, then one share-sheet target or
/// dismiss), then inside Facebook: photo picker (1 tap + photo selects),
/// paste into title/description fields (long-press + Paste per field),
/// price entry, Publish (1 tap). Roughly 8–10 taps end to end. The app
/// never automates anything inside Facebook itself.
class MarketplaceHandoffService {
  /// Facebook Marketplace's create-listing deep link.
  static final Uri createListingUri =
      Uri.parse('https://www.facebook.com/marketplace/create/item');

  /// The single pre-formatted listing text for the clipboard.
  ///
  /// Kept paste-friendly for the Marketplace form: title line, price,
  /// condition, then the description. No footer/branding lines — they
  /// would have to be deleted again inside Facebook.
  String buildHandoffText(Item item) {
    final buffer = StringBuffer()
      ..writeln(item.title)
      ..writeln('Price: \$${item.suggestedPrice.toStringAsFixed(0)}')
      ..writeln('Condition: ${item.condition.label}')
      ..writeln()
      ..write(item.description);
    return buffer.toString();
  }

  /// Builds the [HandoffIntent] for [item] without side effects.
  HandoffIntent buildIntent(Item item) {
    return HandoffIntent(
      clipboardText: buildHandoffText(item),
      createListingUri: createListingUri,
      photoPaths: [item.photoPath, ...item.extraPhotoPaths],
      designedSteps: const [
        'Tap "List on Facebook Marketplace" — Snap2Sell copies your '
            'listing text and opens your photos in the share sheet.',
        'In the share sheet, save the photos or send them where you '
            'can grab them in the Facebook app, then close the sheet.',
        'Snap2Sell opens the Facebook Marketplace "Create listing" '
            'page for you.',
        'In Facebook: add the photos, tap each field and Paste the '
            'copied text, set the price, then tap Publish.',
      ],
    );
  }

  Future<void> copyListingText(Item item) async {
    await Clipboard.setData(ClipboardData(text: buildHandoffText(item)));
  }

  /// Opens the share sheet carrying ONLY the listing photos (the text
  /// is already on the clipboard). Mirrors [ListingService.shareListing]'s
  /// web/mobile handling: on web the photo comes from [photoBytes].
  Future<void> sharePhotos(Item item, {Uint8List? photoBytes}) async {
    if (kIsWeb) {
      if (photoBytes != null) {
        await Share.shareXFiles([
          XFile.fromData(
            photoBytes,
            name: 'snap2sell-photo.jpg',
            mimeType: 'image/jpeg',
          )
        ]);
      }
      return;
    }
    final files = <XFile>[];
    for (final path in [item.photoPath, ...item.extraPhotoPaths]) {
      if (await File(path).exists()) files.add(XFile(path));
    }
    if (files.isNotEmpty) {
      await Share.shareXFiles(files);
    }
  }

  /// Opens Facebook Marketplace's create-listing flow in the Facebook
  /// app / browser. Returns false when nothing could handle the link.
  Future<bool> openCreateListing() {
    return launchUrl(
      createListingUri,
      mode: LaunchMode.externalApplication,
    );
  }

  /// Runs the full handoff: copy → share photos → open create flow.
  /// The create flow is opened after the share sheet closes so the two
  /// do not fight over the screen.
  Future<bool> execute(Item item, {Uint8List? photoBytes}) async {
    await copyListingText(item);
    await sharePhotos(item, photoBytes: photoBytes);
    return openCreateListing();
  }
}
