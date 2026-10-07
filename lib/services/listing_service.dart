import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/item.dart';

/// Marketplace targets supported by the MVP's honest cross-post flow.
/// (See README "Marketplace integrations": no public listing API exists for
/// Facebook Marketplace or OfferUp, so posting = share sheet + clipboard +
/// best-effort sell-page links.)
class Marketplace {
  const Marketplace._(this.name, this.sellUrl);

  final String name;

  /// Best-effort URL that opens the marketplace's "create listing" web flow.
  final String sellUrl;

  static const facebook = Marketplace._(
    'Facebook Marketplace',
    'https://www.facebook.com/marketplace/create/item',
  );
  static const ebay = Marketplace._(
    'eBay',
    'https://www.ebay.com/sl/list',
  );
  static const craigslist = Marketplace._(
    'Craigslist',
    'https://post.craigslist.org/',
  );
  static const offerUp = Marketplace._(
    'OfferUp',
    'https://offerup.com/sell',
  );

  static const List<Marketplace> all = [facebook, ebay, craigslist, offerUp];
}

/// Builds shareable listing copy and hands it to the OS share sheet /
/// clipboard. This is the MVP's cross-post mechanism.
class ListingService {
  /// The full listing text, formatted for pasting into any marketplace.
  String buildListingText(Item item) {
    final buffer = StringBuffer()
      ..writeln(item.title)
      ..writeln()
      ..writeln('Price: \$${item.suggestedPrice.toStringAsFixed(0)}')
      ..writeln('Condition: ${item.condition.label}')
      ..writeln('Category: ${item.category}')
      ..writeln()
      ..writeln(item.description)
      ..writeln()
      ..writeln('— Listed with Snap2Sell: Snap it. Sell it. Done.');
    return buffer.toString();
  }

  /// Short one-liner used on per-platform copy buttons.
  String buildShortText(Item item) =>
      '${item.title} — \$${item.suggestedPrice.toStringAsFixed(0)} (${item.condition.label})';

  Future<void> copyToClipboard(Item item) async {
    await Clipboard.setData(ClipboardData(text: buildListingText(item)));
  }

  Future<void> copyShortToClipboard(Item item) async {
    await Clipboard.setData(ClipboardData(text: buildShortText(item)));
  }

  /// Opens the system share sheet pre-filled with the listing text + photo.
  /// The user picks the target app (Messenger, Messages, Facebook, etc.).
  ///
  /// On web, dart:io files do not exist, so the photo comes from
  /// [photoBytes] (in-memory) instead of [Item.photoPath].
  Future<void> shareListing(Item item, {Uint8List? photoBytes}) async {
    final text = buildListingText(item);
    if (kIsWeb) {
      if (photoBytes != null) {
        await Share.shareXFiles(
          [
            XFile.fromData(
              photoBytes,
              name: 'snap2sell-photo.jpg',
              mimeType: 'image/jpeg',
            )
          ],
          text: text,
          subject: item.title,
        );
      } else {
        await Share.share(text, subject: item.title);
      }
      return;
    }
    final photo = File(item.photoPath);
    if (await photo.exists()) {
      await Share.shareXFiles(
        [XFile(item.photoPath)],
        text: text,
        subject: item.title,
      );
    } else {
      // Photo missing (e.g. cleared cache) — share the text on its own
      // rather than failing the whole post.
      await Share.share(text, subject: item.title);
    }
  }
}
