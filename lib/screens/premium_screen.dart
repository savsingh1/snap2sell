import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../providers/app_state.dart';
import '../services/billing_config.dart';
import '../services/billing_service.dart';

/// Premium screen: the store-billing paywall surface.
///
/// This screen is plumbing proof, not an offer. It is only reachable
/// when store products were configured at build time (the Profile tile
/// that leads here renders only then — see [AppState.billingConfigured]
/// and docs/store-billing.md). Everything on it comes from the store:
/// product titles, descriptions, and prices are whatever the store
/// returns for the configured ids. The app invents no prices, no tier
/// names, and no feature gates — nothing in the app is locked behind
/// this screen.
class PremiumScreen extends StatelessWidget {
  const PremiumScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final billing = context.watch<AppState>().billing;

    return Scaffold(
      appBar: AppBar(title: const Text('Premium')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
        children: _body(context, billing),
      ),
    );
  }

  List<Widget> _body(BuildContext context, BillingService billing) {
    if (!billing.isConfigured) {
      // Honest not-configured state. Unreachable from the UI in a
      // default build (no tile leads here), but if this screen is ever
      // opened directly it tells the truth instead of faking a store.
      return const [
        Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.workspace_premium_rounded,
                    size: 36, color: SnapColors.primary),
                SizedBox(height: 12),
                Text(
                  'Premium is not set up in this build',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 8),
                Text(
                  'No store products have been configured, so there is '
                  'nothing to buy here. Everything in Snap2Sell is '
                  'available — this screen only does something in a '
                  'build where the app owner has set up paid products '
                  'with the store.',
                  style: TextStyle(color: SnapColors.textMuted, height: 1.45),
                ),
              ],
            ),
          ),
        ),
      ];
    }

    switch (billing.state) {
      case BillingServiceState.notConfigured:
        // isConfigured was true above, so this cannot happen; keep the
        // switch exhaustive without inventing a UI for it.
        return const [SizedBox.shrink()];
      case BillingServiceState.initialising:
        return const [
          Padding(
            padding: EdgeInsets.only(top: 64),
            child: Center(child: CircularProgressIndicator()),
          ),
          SizedBox(height: 16),
          Center(
            child: Text(
              'Contacting the store…',
              style: TextStyle(color: SnapColors.textMuted),
            ),
          ),
        ];
      case BillingServiceState.storeUnavailable:
        return [
          _MessageCard(
            icon: Icons.storefront_rounded,
            title: 'The store is not available',
            body: 'This device cannot reach the app store right now, '
                'so paid options cannot be loaded. Everything else in '
                'Snap2Sell works as usual.',
            actionLabel: 'Try again',
            onAction: () => billing.initialise(),
          ),
        ];
      case BillingServiceState.error:
        return [
          _MessageCard(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load paid options',
            body: billing.lastError ??
                'Something went wrong while talking to the store.',
            actionLabel: 'Try again',
            onAction: () => billing.initialise(),
          ),
        ];
      case BillingServiceState.ready:
        return _ready(context, billing);
    }
  }

  List<Widget> _ready(BuildContext context, BillingService billing) {
    final widgets = <Widget>[
      const Text(
        'Paid options from the store',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 4),
      const Text(
        'Prices and details are set by the store listing for each '
        'product. Buying is handled entirely by the store.',
        style: TextStyle(color: SnapColors.textMuted, height: 1.45),
      ),
      const SizedBox(height: 16),
    ];

    if (billing.lastError != null) {
      widgets.addAll([
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFDECEA),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFEF9A9A)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 20, color: Color(0xFFB3261E)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  billing.lastError!,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFFB3261E)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ]);
    }

    for (final product in billing.products) {
      widgets.addAll([
        _ProductCard(billing: billing, product: product),
        const SizedBox(height: 12),
      ]);
    }

    if (billing.notFoundProductIds.isNotEmpty) {
      widgets.addAll([
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Some configured products could not be loaded from the '
              'store. They may still be getting set up.',
              style: TextStyle(color: SnapColors.textMuted, height: 1.45),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ]);
    }

    if (billing.hasEntitlement && !billing.hasVerifiedEntitlement) {
      widgets.addAll([
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Your purchase is recorded on this device. Server '
              'verification is not set up yet, so it is not treated as '
              'confirmed.',
              style: TextStyle(color: SnapColors.textMuted, height: 1.45),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ]);
    }

    widgets.add(
      OutlinedButton.icon(
        onPressed: () => billing.restorePurchases(),
        icon: const Icon(Icons.restore_rounded),
        label: const Text('Restore purchases'),
      ),
    );
    return widgets;
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.billing, required this.product});

  final BillingService billing;
  final StoreProduct product;

  @override
  Widget build(BuildContext context) {
    final owned = billing.isOwned(product.id);
    final pending = billing.pendingProductId == product.id;
    final anyPending = billing.pendingProductId != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    product.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  product.price,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: SnapColors.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              _kindLabel(product.kind),
              style: const TextStyle(
                color: SnapColors.textMuted,
                fontSize: 12,
              ),
            ),
            if (product.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                product.description,
                style: const TextStyle(height: 1.45),
              ),
            ],
            const SizedBox(height: 16),
            if (owned)
              const Row(
                children: [
                  Icon(Icons.check_circle_rounded,
                      color: SnapColors.accentDark, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Owned on this device',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              )
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: anyPending
                      ? null
                      : () => billing.buy(product.id),
                  child: pending
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Buy'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Factual description of the product kind from build config — not a
  /// tier name and not marketing copy.
  static String _kindLabel(BillingProductKind kind) => switch (kind) {
        BillingProductKind.subscription => 'Subscription',
        BillingProductKind.nonConsumable => 'One-time purchase',
        BillingProductKind.consumable => 'Consumable purchase',
      };
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 36, color: SnapColors.primary),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: const TextStyle(color: SnapColors.textMuted, height: 1.45),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
