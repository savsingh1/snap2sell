import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../providers/app_state.dart';
import 'results_screen.dart';

/// Animated AI pipeline screen. Watches [AppState] and moves to the
/// Results screen when analysis completes.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key});

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  bool _sawAnalyzing = false;
  bool _navigated = false;

  void _maybeAdvance(BuildContext context, AppState appState) {
    if (appState.isAnalyzing) _sawAnalyzing = true;
    if (_sawAnalyzing && !appState.isAnalyzing && !_navigated) {
      _navigated = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (appState.analysisError != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(appState.analysisError!)),
          );
        }
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ResultsScreen()),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    _maybeAdvance(context, appState);

    final step = appState.analysisStep.clamp(0, kAnalysisSteps.length - 1);
    final progress = appState.isAnalyzing
        ? (step + 1) / kAnalysisSteps.length
        : 0.05;
    final photoBytes = appState.currentPhotoBytes;

    return Scaffold(
      appBar: AppBar(title: const Text('AI Analysis')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Center(
              child: _PulseGlow(
                child: SizedBox(
                  width: 120,
                  height: 120,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // The ring eases between step values instead of
                      // jumping a quarter-turn at a time.
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0, end: progress),
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, _) => SizedBox(
                          width: 120,
                          height: 120,
                          child: CircularProgressIndicator(
                            value: value,
                            strokeWidth: 10,
                            backgroundColor: SnapColors.primaryLight,
                            valueColor:
                                const AlwaysStoppedAnimation<Color>(
                              SnapColors.primary,
                            ),
                          ),
                        ),
                      ),
                      // The user's own photo sits inside the ring while
                      // it is analysed, and flies into the Results
                      // preview via the shared Hero tag.
                      if (photoBytes != null)
                        Hero(
                          tag: 'snap-photo-hero',
                          child: ClipOval(
                            child: Image.memory(
                              photoBytes,
                              width: 88,
                              height: 88,
                              fit: BoxFit.cover,
                            ),
                          ),
                        )
                      else
                        const SnapLogo(size: 72),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              'Analyzing your item…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              'Our AI is identifying the item, checking its condition and '
              'comparing live resale prices.',
              textAlign: TextAlign.center,
              style: TextStyle(color: SnapColors.textMuted, fontSize: 14),
            ),
            const SizedBox(height: 28),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    for (var i = 0; i < kAnalysisSteps.length; i++)
                      _StepRow(
                        label: kAnalysisSteps[i],
                        state: !appState.isAnalyzing
                            ? _StepState.pending
                            : i < step
                                ? _StepState.done
                                : i == step
                                    ? _StepState.active
                                    : _StepState.pending,
                      ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: appState.isAnalyzing
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A slow breathing halo behind the progress ring while analysis runs.
class _PulseGlow extends StatefulWidget {
  const _PulseGlow({required this.child});

  final Widget child;

  @override
  State<_PulseGlow> createState() => _PulseGlowState();
}

class _PulseGlowState extends State<_PulseGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_pulse.value);
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // Positioned so the halo never affects layout size.
            Positioned(
              left: -9,
              top: -9,
              child: Container(
                width: 138,
                height: 138,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: SnapColors.primary
                      .withValues(alpha: 0.05 + 0.06 * t),
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: widget.child,
    );
  }
}

enum _StepState { pending, active, done }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final Color iconColor;
    final Widget trailing;
    switch (state) {
      case _StepState.done:
        iconColor = SnapColors.accentDark;
        trailing = const Icon(Icons.check_circle_rounded,
            color: SnapColors.accentDark);
        break;
      case _StepState.active:
        iconColor = SnapColors.primary;
        trailing = const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        );
        break;
      case _StepState.pending:
        iconColor = SnapColors.textMuted;
        trailing = const Icon(Icons.radio_button_unchecked_rounded,
            color: Color(0xFFDCD3F5));
        break;
    }
    return ListTile(
      dense: true,
      leading: Icon(
        state == _StepState.done
            ? Icons.check_circle_rounded
            : Icons.autorenew_rounded,
        color: iconColor,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontWeight:
              state == _StepState.active ? FontWeight.w700 : FontWeight.w500,
          color: state == _StepState.pending
              ? SnapColors.textMuted
              : SnapColors.textDark,
        ),
      ),
      trailing: trailing,
    );
  }
}
