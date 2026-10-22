import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_marker_model.dart';

/// Persists the user's saved markers in SharedPreferences under its own key,
/// fully independent of saved tracks and imported KML layers.
class SavedMarkerService {
  static const String _prefKey = 'Grahana_saved_markers_v1';

  static Future<List<SavedMarker>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final result = <SavedMarker>[];
      for (final item in decoded) {
        try {
          result.add(SavedMarker.fromJson(item as Map<String, dynamic>));
        } catch (_) {
          // Skip a single corrupted entry instead of losing every marker.
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<SavedMarker> markers) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefKey,
        jsonEncode(markers.map((m) => m.toJson()).toList()),
      );
    } catch (_) {
      // Storage failure must never crash the map screen.
    }
  }
}
