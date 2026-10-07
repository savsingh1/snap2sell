import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_navigator.dart';
import '../app_theme.dart';
import '../providers/app_state.dart';
import '../widgets/capture_helpers.dart';

/// Step 6: success state after the share sheet, with next actions.
class ConfirmationScreen extends StatelessWidget {
  const ConfirmationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final item = appState.currentItem;

    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(),
            Center(
              child: Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: SnapColors.accent.withValues(alpha: 0.25),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  size: 56,
                  color: SnapColors.accentDark,
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Listing Draft Ready!',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              item == null
                  ? 'Your listing is saved and ready to post anywhere.'
                  : '"${item.title}" is saved. Paste it into any marketplace '
                      'from your clipboard or share sheet.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SnapColors.textMuted,
                fontSize: 15,
                height: 1.45,
              ),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: item == null
                  ? null
                  : () async {
                      await appState.listingService.copyToClipboard(item);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content:
                                  Text('Listing copied to clipboard')),
                        );
                      }
                    },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy to Clipboard'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => goHome(context),
              child: const Text('Save for Later'),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                goHome(context);
                // The confirmation screen is disposed by goHome, so open the
                // sheet from the app navigator's still-mounted context.
                Future<void>.delayed(const Duration(milliseconds: 400), () {
                  final navContext = appNavigatorKey.currentContext;
                  if (navContext != null && navContext.mounted) {
                    showCaptureSheet(navContext);
                  }
                });
              },
              icon: const Icon(Icons.add_a_photo_rounded),
              label: const Text('Start Another'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
