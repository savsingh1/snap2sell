import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/item.dart';
import '../providers/app_state.dart';
import '../widgets/capture_helpers.dart';
import '../widgets/item_card.dart';

/// Dashboard: Snap CTA, inventory value summary, recent items.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            SnapLogo(size: 36),
            SizedBox(width: 10),
            Text('Snap2Sell'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Snap an item',
            onPressed: () => showCaptureSheet(context),
            icon: const Icon(Icons.add_a_photo_rounded,
                color: SnapColors.primary),
          ),
        ],
      ),
      body: !appState.isLoaded
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => appState.init(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                children: [
                  _SnapCtaCard(),
                  const SizedBox(height: 16),
                  _ValueSummaryCard(),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Recent Items',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (appState.items.isNotEmpty)
                        Text(
                          '${appState.items.length} total',
                          style: const TextStyle(
                            color: SnapColors.textMuted,
                            fontSize: 13,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (appState.items.isEmpty)
                    _EmptyState()
                  else
                    for (final item in appState.recentItems) ...[
                      ItemCard(item: item),
                      const SizedBox(height: 10),
                    ],
                ],
              ),
            ),
    );
  }
}

class _SnapCtaCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [SnapColors.primary, SnapColors.primaryDark],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Turn clutter into cash',
              style: TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Snap a photo — AI handles the title, price and description.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => showCaptureSheet(context),
                icon: const Icon(Icons.photo_camera_rounded),
                label: const Text('Snap an Item'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: SnapColors.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ValueSummaryCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final active = appState.items
        .where((i) => i.status != ListingStatus.sold)
        .length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: SnapColors.accent.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.savings_rounded,
                  color: SnapColors.accentDark, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Estimated inventory value',
                    style: TextStyle(
                      color: SnapColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    '\$${appState.estimatedInventoryValue.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: SnapColors.textDark,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '$active active',
              style: const TextStyle(
                color: SnapColors.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: const BoxDecoration(
                color: SnapColors.primaryLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.photo_camera_rounded,
                size: 40,
                color: SnapColors.primary,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'No items yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Snap your first item and watch AI write the listing for you.',
              textAlign: TextAlign.center,
              style: TextStyle(color: SnapColors.textMuted, fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => showCaptureSheet(context),
              child: const Text('Snap your first item'),
            ),
          ],
        ),
      ),
    );
  }
}
