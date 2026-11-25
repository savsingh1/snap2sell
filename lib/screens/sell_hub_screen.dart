import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/item.dart';
import '../providers/app_state.dart';
import '../services/facebook_auth_service.dart';
import '../services/marketplace_handoff.dart';
import '../services/sell_destination.dart';

/// "Sell it" hub: every place a finished listing can go, with an honest
/// status for each destination.
///
/// Facebook Marketplace has no posting API, so its action runs the
/// packaged handoff (copy → share photos → open the create page).
/// Facebook Shop and eBay have real APIs but need seller setup, so they
/// show exactly what is missing instead of a fake "Post" button. The
/// remaining marketplaces have no public listing API at all and are
/// greyed as "coming".
class SellHubScreen extends StatefulWidget {
  const SellHubScreen({super.key});

  @override
  State<SellHubScreen> createState() => _SellHubScreenState();
}

class _SellHubScreenState extends State<SellHubScreen> {
  final FacebookAuthService _facebookAuth = ConfigGatedFacebookAuthService();
  final MarketplaceHandoffService _handoff = MarketplaceHandoffService();
  bool _handoffRunning = false;

  Future<void> _connectFacebook() async {
    final result = await _facebookAuth.connect();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  Future<void> _runMarketplaceHandoff(AppState appState) async {
    final item = appState.currentItem;
    if (item == null || _handoffRunning) return;
    setState(() => _handoffRunning = true);
    final opened = await _handoff.execute(
      item,
      photoBytes: appState.currentPhotoBytes,
    );
    if (!mounted) return;
    setState(() => _handoffRunning = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(opened
            ? 'Listing text copied. In Facebook: add your photos, '
                'paste the text, set the price, then Publish.'
            : 'Listing text copied and photos shared, but the '
                'Marketplace page could not be opened. Open Facebook '
                'Marketplace and tap "Create new listing".'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final item = appState.currentItem;

    if (item == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Sell it')),
        body: const Center(child: Text('No item to sell yet.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Sell it')),
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
                        Text(
                          item.title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${item.priceDisplay} · ${item.condition.label}',
                          style: const TextStyle(
                            color: SnapColors.textMuted,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: SnapColors.primaryLight,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.storefront_rounded,
                        color: SnapColors.primary, size: 28),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          _FacebookConnectionCard(
            state: _facebookAuth.state,
            onConnect: _connectFacebook,
          ),
          const SizedBox(height: 20),
          const Text(
            'Where to list it',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          for (final destination in SellDestination.all) ...[
            _DestinationCard(
              destination: destination,
              onAction: destination == SellDestination.facebookMarketplace
                  ? () => _runMarketplaceHandoff(appState)
                  : null,
              actionBusy: _handoffRunning &&
                  destination == SellDestination.facebookMarketplace,
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _FacebookConnectionCard extends StatelessWidget {
  const _FacebookConnectionCard({
    required this.state,
    required this.onConnect,
  });

  final FacebookConnectionState state;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final (statusText, detail) = switch (state) {
      FacebookConnectionState.notConfigured => (
          'Not set up yet',
          'Connecting a Facebook account needs a one-time Meta app '
              'setup by the app owner. Until then, use the Marketplace '
              'handoff below — it works without any login.',
        ),
      FacebookConnectionState.disconnected => (
          'Not connected',
          'Connect Facebook to use the Shop/catalog route. '
              'Marketplace posting always stays a handoff — Facebook '
              'does not let apps post to personal Marketplace profiles.',
        ),
      FacebookConnectionState.connected => (
          'Connected',
          'Your Facebook account is connected for the Shop/catalog '
              'route.',
        ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.facebook,
                    color: SnapColors.primary, size: 26),
                const SizedBox(width: 10),
                const Text(
                  'Facebook account',
                  style:
                      TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  statusText,
                  style: const TextStyle(
                    color: SnapColors.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              style: const TextStyle(
                  color: SnapColors.textMuted, fontSize: 13.5),
            ),
            if (state != FacebookConnectionState.connected) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onConnect,
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Connect Facebook'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DestinationCard extends StatelessWidget {
  const _DestinationCard({
    required this.destination,
    required this.onAction,
    required this.actionBusy,
  });

  final SellDestination destination;
  final VoidCallback? onAction;
  final bool actionBusy;

  String get _kindLabel => switch (destination.kind) {
        SellDestinationKind.handoff => 'HANDOFF',
        SellDestinationKind.catalog => 'BUSINESS',
        SellDestinationKind.api => 'API',
        SellDestinationKind.coming => 'COMING SOON',
      };

  @override
  Widget build(BuildContext context) {
    final greyed = destination.kind == SellDestinationKind.coming;
    return Opacity(
      opacity: greyed ? 0.55 : 1,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      destination.name,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: SnapColors.primaryLight,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _kindLabel,
                      style: const TextStyle(
                        color: SnapColors.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                destination.tagline,
                style: const TextStyle(
                    color: SnapColors.textMuted, fontSize: 13.5),
              ),
              const SizedBox(height: 12),
              if (destination.isActionable)
                ElevatedButton.icon(
                  onPressed: actionBusy ? null : onAction,
                  icon: actionBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(destination.actionLabel!),
                )
              else
                Row(
                  children: [
                    const Icon(Icons.lock_rounded,
                        size: 16, color: SnapColors.textMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        destination.blockedReason ?? '',
                        style: const TextStyle(
                          color: SnapColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
