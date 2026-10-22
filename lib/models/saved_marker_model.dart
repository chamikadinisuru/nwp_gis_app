import 'package:latlong2/latlong.dart';

/// A marker the user added from the "Saved Markers" tab.
///
/// This is intentionally a separate model from `GISMarkerData` (used for
/// KML imports / track markers) so that saving, loading and clearing tracks
/// or KML layers never touches these markers, and vice-versa.
class SavedMarker {
  final String id;
  final LatLng position;
  String name;
  String description;
  String markerType; // key of kMarkerTypeColors, e.g. 'general', 'issue'
  final DateTime createdAt;

  SavedMarker({
    required this.id,
    required this.position,
    required this.name,
    this.description = '',
    this.markerType = 'general',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'lat': position.latitude,
    'lng': position.longitude,
    'name': name,
    'desc': description,
    'markerType': markerType,
    'createdAt': createdAt.toIso8601String(),
  };

  factory SavedMarker.fromJson(Map<String, dynamic> json) => SavedMarker(
    id: json['id'].toString(),
    position: LatLng(
      (json['lat'] as num).toDouble(),
      (json['lng'] as num).toDouble(),
    ),
    name: json['name']?.toString() ?? '',
    description: json['desc']?.toString() ?? '',
    markerType: json['markerType']?.toString() ?? 'general',
    createdAt:
        DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
        DateTime.now(),
  );
}
