import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/item.dart';

/// Persistence contract. The app is local-first for the MVP; the interface
/// is deliberately narrow so a Firebase implementation
/// (Firestore + Storage + Auth) can be dropped in later without touching
/// the UI or state layer. See FIREBASE_SETUP.md.
abstract class StorageService {
  Future<List<Item>> loadItems();
  Future<void> saveItems(List<Item> items);
}

/// Local-first implementation backed by shared_preferences.
/// Items are stored as a single JSON array; photos live in the app documents
/// directory (see AppState.pickAndStart) and are referenced by path.
class LocalStorageService implements StorageService {
  static const String _prefsKey = 'snap2sell_items_v1';

  @override
  Future<List<Item>> loadItems() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return <Item>[];

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final items = decoded
          .map((e) => Item.fromJson(e as Map<String, dynamic>))
          .toList();
      // Newest first.
      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return items;
    } catch (_) {
      // Corrupt cache should never brick the app — start fresh.
      return <Item>[];
    }
  }

  @override
  Future<void> saveItems(List<Item> items) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(items.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, raw);
  }
}
