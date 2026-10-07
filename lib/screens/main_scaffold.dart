import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../widgets/capture_helpers.dart';
import 'home_screen.dart';
import 'profile_screen.dart';

/// Tab scaffold: Home | Snap (center action) | Profile.
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _tab = 0;

  void _onTap(int index) {
    if (index == 1) {
      // Center action opens the camera/gallery sheet, not a tab.
      showCaptureSheet(context);
      return;
    }
    setState(() => _tab = index > 1 ? 1 : index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [
          HomeScreen(),
          ProfileScreen(),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showCaptureSheet(context),
        tooltip: 'Snap an item',
        child: const Icon(Icons.photo_camera_rounded, size: 30),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        padding: EdgeInsets.zero,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _TabButton(
              icon: Icons.home_rounded,
              label: 'Home',
              selected: _tab == 0,
              onTap: () => _onTap(0),
            ),
            const SizedBox(width: 48), // space for the FAB notch
            _TabButton(
              icon: Icons.person_rounded,
              label: 'Profile',
              selected: _tab == 1,
              onTap: () => _onTap(2),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color =
        selected ? SnapColors.primary : SnapColors.textMuted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight:
                    selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
