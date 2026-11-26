import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_theme.dart';
import '../widgets/capture_helpers.dart';
import 'main_scaffold.dart';

/// First-run screen: brand hero, capture CTA, photo tips.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..forward();

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.5, 1],
                  colors: [
                    Color(0xFF6A3DF0),
                    SnapColors.primary,
                    SnapColors.primaryDeep,
                  ],
                ),
              ),
            ),
          ),
          // Faint teal sheen from the logo accent, top right.
          Positioned(
            top: -90,
            right: -70,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    SnapColors.accent.withValues(alpha: 0.16),
                    SnapColors.accent.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Scroll-safe on short screens; spacers still distribute the
              // hero nicely when there is room to spare.
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Column(
                        children: [
                const Spacer(flex: 2),
                _Entrance(
                  animation: _intro,
                  interval: const Interval(0, 0.65, curve: Curves.easeOut),
                  dy: 14,
                  child: Column(
                    children: [
                      const SnapLogo(size: 96),
                      const SizedBox(height: 20),
                      const Text(
                        'Snap2Sell',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 40,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Snap it. Sell it. Done.',
                        style: TextStyle(
                          color: SnapColors.accent,
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Snap a photo of any household item and AI writes '
                        'the listing, prices it, and preps it for every '
                        'marketplace.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 15,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 2),
                _Entrance(
                  animation: _intro,
                  interval: const Interval(0.3, 1, curve: Curves.easeOut),
                  dy: 18,
                  child: Column(
                    children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () =>
                        startCaptureFlow(context, ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_rounded),
                    label: const Text('Take a Photo'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: SnapColors.primary,
                      shadowColor: Colors.black26,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        startCaptureFlow(context, ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_rounded),
                    label: const Text('Upload from Gallery'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side:
                          const BorderSide(color: Colors.white70, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                _TipsCard(),
                    ],
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                        builder: (_) => const MainScaffold()),
                  ),
                  child: Text(
                    'Skip to dashboard',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          ),
        ],
      ),
    );
  }
}

/// One entrance group for the welcome hero: fades in while rising a few
/// pixels, on its own slice of the shared intro animation.
class _Entrance extends StatelessWidget {
  const _Entrance({
    required this.animation,
    required this.interval,
    required this.dy,
    required this.child,
  });

  final Animation<double> animation;
  final Interval interval;
  final double dy;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: interval);
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) => Opacity(
        opacity: curved.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, dy * (1 - curved.value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _TipsCard extends StatelessWidget {
  static const _tips = [
    'Use natural daylight — avoid flash.',
    'Fill the frame with the item.',
    'Include flaws honestly — buyers trust it.',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Photo tips',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          for (final tip in _tips)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.check_circle_rounded,
                      color: SnapColors.accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tip,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
  }
