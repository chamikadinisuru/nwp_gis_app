class RoadModel {
  final double id;
  final String rNumber;
  final String rName;
  final String authority;
  final String type;
  final double length;
  final double width;
  final double? devWidth;
  final List<List<double>> coordinates; // [lng, lat] pairs (first line of MultiLineString)

  RoadModel({
    required this.id,
    required this.rNumber,
    required this.rName,
    required this.authority,
    required this.type,
    required this.length,
    required this.width,
    this.devWidth,
    required this.coordinates,
  });

  factory RoadModel.fromFeature(Map<String, dynamic> feature) {
    final props = feature['properties'] as Map<String, dynamic>;
    final geom = feature['geometry'] as Map<String, dynamic>;
    final coords = <List<double>>[];

    // MultiLineString or LineString
    if (geom['type'] == 'MultiLineString') {
      final lines = geom['coordinates'] as List;
      if (lines.isNotEmpty) {
        for (final pt in (lines[0] as List)) {
          coords.add([(pt[0] as num).toDouble(), (pt[1] as num).toDouble()]);
        }
      }
    } else if (geom['type'] == 'LineString') {
      for (final pt in (geom['coordinates'] as List)) {
        coords.add([(pt[0] as num).toDouble(), (pt[1] as num).toDouble()]);
      }
    }

    return RoadModel(
      id: (props['ID'] as num?)?.toDouble() ?? 0,
      rNumber: props['R_NUMBER']?.toString() ?? '',
      rName: props['R_NAME']?.toString() ?? '',
      authority: props['AUTHORITY']?.toString() ?? '',
      type: props['TYPE']?.toString() ?? '',
      length: (props['LENGTH'] as num?)?.toDouble() ?? 0,
      width: (props['WIDTH'] as num?)?.toDouble() ?? 0,
      devWidth: (props['DEV_WIDTH'] as num?)?.toDouble(),
      coordinates: coords,
    );
  }

  String get typeLabel {
    switch (type.toUpperCase()) {
      case 'TAR':
        return 'Tar / Asphalt';
      case 'GRV':
        return 'Gravel';
      case 'CNC':
        return 'Concrete';
      case 'CPT':
        return 'Carpet';
      default:
        return type;
    }
  }
}
