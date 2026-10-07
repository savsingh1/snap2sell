import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../screens/main_scaffold.dart';
import '../screens/processing_screen.dart';

/// Shows the Camera / Gallery picker sheet used across the app.
Future<void> showCaptureSheet(BuildContext context) async {
  final choice = await showModalBottomSheet<ImageSource>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded, size: 28),
              title: const Text('Take a Photo',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Snap the item right now'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, size: 28),
              title: const Text('Upload from Gallery',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Pick a photo you already took'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice != null && context.mounted) {
    await startCaptureFlow(context, choice);
  }
}

/// Pushes the Processing screen, then runs the AI pipeline.
/// If the user cancels the image picker, the Processing screen is popped.
Future<void> startCaptureFlow(BuildContext context, ImageSource source) async {
  final appState = context.read<AppState>();
  final navigator = Navigator.of(context);
  navigator.push(
    MaterialPageRoute(builder: (_) => const ProcessingScreen()),
  );
  final item = await appState.pickAndAnalyze(source);
  if (item == null && navigator.canPop()) {
    // User cancelled the picker before analysis started.
    navigator.pop();
  }
  // Otherwise the Processing screen navigates onward by itself.
}

/// Returns to the main tab scaffold, clearing the listing flow stack.
void goHome(BuildContext context) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const MainScaffold()),
    (route) => false,
  );
}

/// Small helper for "coming soon" tiles.
void showComingSoon(BuildContext context, String feature) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$feature is coming in a future update.')),
  );
}
