import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import '../models/item.dart';
import '../providers/app_state.dart';
import '../services/listing_service.dart';
import 'confirmation_screen.dart';

/// Step 5: choose marketplaces, then "post" via the system share sheet.
///
/// HONEST MECHANISM (see README): Facebook Marketplace and OfferUp expose no
/// public listing API, so one-tap API posting is impossible. "Post Listing"
/// opens the OS share sheet with the listing text + photo, each platform row
/// has its own copy button, and the external-link icon opens that
/// marketplace's sell page where the user finishes the post.
class PlatformsScreen extends StatelessWidget {
  const PlatformsScreen({super.key});

  Future<void> _post(BuildContext context, AppState appState) async {
    final item = appState.currentItem;
    if (item == null) return;
    await appState.saveCurrentItem(status: ListingStatus.ready);
    await appState.listingService.shareListing(
      item,
      photoBytes: appState.currentPhotoBytes,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ConfirmationScreen()),
    );
  }

  Future<void> _openSellPage(BuildContext context, Marketplace m) async {
    final uri = Uri.parse(m.sellUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${m.name}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final item = appState.currentItem;

    if (item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('No item to post.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Price & Platforms')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Your list price',
                          style: TextStyle(
                            color: SnapColors.textMuted,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '\$${item.suggestedPrice.toStringAsFixed(0)}',
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: SnapColors.primary,
                          ),
                        ),
                        Text(
                          'AI range ${item.rangeDisplay}',
                          style: const TextStyle(
                            color: SnapColors.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: SnapColors.primaryLight,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.sell_rounded,
                        color: SnapColors.primary, size: 32),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Post to marketplaces',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'Tick where you want to list. Posting opens your share sheet '
            'with the listing text and photo ready to paste.',
            style: TextStyle(color: SnapColors.textMuted, fontSize: 13.5),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < Marketplace.all.length; i++) ...[
                  _PlatformRow(
                    marketplace: Marketplace.all[i],
                    checked: appState.selectedPlatforms
                        .contains(Marketplace.all[i].name),
                    onToggle: () =>
                        appState.togglePlatform(Marketplace.all[i].name),
                    onCopy: () async {
                      await appState.listingService
                          .copyShortToClipboard(item);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                                '${Marketplace.all[i].name} listing copied'),
                          ),
                        );
                      }
                    },
                    onOpen: () =>
                        _openSellPage(context, Marketplace.all[i]),
                  ),
                  if (i < Marketplace.all.length - 1)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => _post(context, appState),
            icon: const Icon(Icons.ios_share_rounded),
            label: const Text('Post Listing'),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Opens the share sheet with your photo + listing text',
              style: TextStyle(
                color: SnapColors.textMuted,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlatformRow extends StatelessWidget {
  const _PlatformRow({
    required this.marketplace,
    required this.checked,
    required this.onToggle,
    required this.onCopy,
    required this.onOpen,
  });

  final Marketplace marketplace;
  final bool checked;
  final VoidCallback onToggle;
  final VoidCallback onCopy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Checkbox(
        value: checked,
        activeColor: SnapColors.primary,
        onChanged: (_) => onToggle(),
      ),
      title: Text(
        marketplace.name,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Copy listing for ${marketplace.name}',
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded,
                color: SnapColors.textMuted, size: 20),
          ),
          IconButton(
            tooltip: 'Open ${marketplace.name} sell page',
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new_rounded,
                color: SnapColors.primary, size: 20),
          ),
        ],
      ),
      onTap: onToggle,
    );
  }
}
