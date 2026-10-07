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

    return Scaffold(
      appBar: AppBar(title: const Text('AI Analysis')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Center(
              child: SizedBox(
                width: 120,
                height: 120,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 120,
                      height: 120,
                      child: CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 10,
                        backgroundColor: SnapColors.primaryLight,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          SnapColors.primary,
                        ),
                      ),
                    ),
                    const SnapLogo(size: 72),
                  ],
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
            color: Color(0xFFD8D4E8));
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
