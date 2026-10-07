import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/item.dart';
import '../providers/app_state.dart';
import '../widgets/capture_helpers.dart';

/// Step 7: profile — account, payment methods, past listings, help.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final posted =
        appState.items.where((i) => i.status == ListingStatus.posted).length;
    final sold =
        appState.items.where((i) => i.status == ListingStatus.sold).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: SnapColors.primaryLight,
                    child: Icon(Icons.person_rounded,
                        size: 36, color: SnapColors.primary),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Guest Seller',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Sign in to sync listings across devices',
                          style: TextStyle(
                            color: SnapColors.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _Stat(
                      value: '${appState.items.length}', label: 'Listings'),
                  _Stat(value: '$posted', label: 'Posted'),
                  _Stat(value: '$sold', label: 'Sold'),
                  _Stat(
                    value:
                        '\$${appState.estimatedInventoryValue.toStringAsFixed(0)}',
                    label: 'Inventory',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                _Tile(
                  icon: Icons.payments_rounded,
                  title: 'Payment Methods',
                  subtitle: 'Add payout accounts for sold items',
                  onTap: () => showComingSoon(context, 'Payment methods'),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                _Tile(
                  icon: Icons.history_rounded,
                  title: 'Past Listings',
                  subtitle:
                      '${appState.items.length} in your library',
                  onTap: () => showComingSoon(
                      context, 'The full listings archive'),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                _Tile(
                  icon: Icons.help_outline_rounded,
                  title: 'Help & Support',
                  subtitle: 'FAQs and contact us',
                  onTap: () => _showHelp(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Snap2Sell v0.1.0 • Snap it. Sell it. Done.',
              style: TextStyle(
                color: SnapColors.textMuted.withValues(alpha: 0.8),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Help & Support'),
        content: const Text(
          'How it works:\n\n'
          '1. Snap a photo of your item.\n'
          '2. AI identifies it, grades the condition and suggests a price.\n'
          '3. Review and edit the listing.\n'
          '4. Tick your marketplaces and tap Post Listing — your share '
          'sheet opens with the photo and text ready.\n\n'
          'Questions? Email support@zoomindustries.ca',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: SnapColors.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: SnapColors.textMuted,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: SnapColors.primaryLight,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: SnapColors.primary, size: 22),
      ),
      title: Text(title,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle,
          style:
              const TextStyle(color: SnapColors.textMuted, fontSize: 13)),
      trailing: const Icon(Icons.chevron_right_rounded,
          color: SnapColors.textMuted),
      onTap: onTap,
    );
  }
}
