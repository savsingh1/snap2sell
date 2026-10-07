import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/item.dart';
import '../providers/app_state.dart';
import '../screens/results_screen.dart';

/// Thumbnail row used for "Recent Items" on Home (and Past Listings).
class ItemCard extends StatelessWidget {
  const ItemCard({super.key, required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          appState.openItem(item);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ResultsScreen()),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _Thumbnail(path: item.photoPath),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        _Pill(
                          item.condition.label,
                          color: SnapColors.teal,
                        ),
                        _Pill(
                          item.status.label,
                          color: SnapColors.primary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    item.priceDisplay,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                      color: SnapColors.primary,
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert,
                        color: SnapColors.textMuted),
                    onSelected: (value) async {
                      if (value == 'sold') {
                        await appState.markSold(item.id);
                      } else if (value == 'delete') {
                        await appState.deleteItem(item.id);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'sold', child: Text('Mark as sold')),
                      PopupMenuItem(
                          value: 'delete', child: Text('Delete')),
                    ],
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

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final Widget image;
    if (kIsWeb) {
      // Web keeps photos in memory for the session only; past listings
      // show the placeholder thumbnail.
      image = Container(
        color: SnapColors.primaryLight,
        child:
            const Icon(Icons.image_rounded, color: SnapColors.primary),
      );
    } else {
      final file = File(path);
      image = file.existsSync()
          ? Image.file(file, fit: BoxFit.cover)
          : Container(
              color: SnapColors.primaryLight,
              child: const Icon(Icons.image_rounded,
                  color: SnapColors.primary),
            );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 72,
        height: 72,
        child: image,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color == SnapColors.primary
              ? SnapColors.primary
              : SnapColors.accentDark,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
