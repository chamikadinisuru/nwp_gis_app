import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

/// One GND-level feature from boundary.geojson: its full attribute set
/// (Province / District / DSD / GND / PS name) plus the ring(s) that make
/// up its shape. Kept separate per-GND (instead of only merging everything
/// into one big polygon per PS) so tapping the map can tell exactly which
/// GND / boundary piece was tapped, not just which PS it belongs to.
class BoundaryFeature {
  final String psName;
  final Map<String, dynamic> props;
  final List<List<LatLng>> rings;

  BoundaryFeature({
    required this.psName,
    required this.props,
    required this.rings,
  });
}

class _ParsedBoundary {
  final List<BoundaryFeature> features;
  final List<String> psNames;
  _ParsedBoundary(this.features, this.psNames);
}

// Parses boundary.geojson (thousands of GND polygons, several MB) into
// BoundaryFeatures. Runs on a background isolate via compute() - this is
// pure CPU/JSON work with no dependency on any app state, so it's safe to
// run off the UI thread, keeping the app responsive on lower-end devices
// (e.g. Android 10 phones with limited RAM/CPU) instead of freezing while
// it decodes.
_ParsedBoundary _parseBoundaryJson(String raw) {
  final data = json.decode(raw) as Map<String, dynamic>;
  final features = data['features'] as List;

  final list = <BoundaryFeature>[];
  final namesSet = <String>{};

  for (final f in features) {
    final props = Map<String, dynamic>.from(
      f['properties'] as Map<String, dynamic>,
    );
    final name = props['MC_UC_PS_N']?.toString() ?? '';
    if (name.isEmpty) continue;

    final geom = f['geometry'] as Map<String, dynamic>;
    final rings = <List<LatLng>>[];

    if (geom['type'] == 'MultiPolygon') {
      for (final poly in (geom['coordinates'] as List)) {
        if (poly is List && poly.isNotEmpty) {
          final ring = <LatLng>[];
          for (final pt in (poly[0] as List)) {
            ring.add(
              LatLng((pt[1] as num).toDouble(), (pt[0] as num).toDouble()),
            );
          }
          if (ring.length >= 3) rings.add(ring);
        }
      }
    } else if (geom['type'] == 'Polygon') {
      final coords = geom['coordinates'] as List;
      if (coords.isNotEmpty) {
        final ring = <LatLng>[];
        for (final pt in (coords[0] as List)) {
          ring.add(
            LatLng((pt[1] as num).toDouble(), (pt[0] as num).toDouble()),
          );
        }
        if (ring.length >= 3) rings.add(ring);
      }
    }

    if (rings.isEmpty) continue;
    list.add(BoundaryFeature(psName: name, props: props, rings: rings));
    namesSet.add(name);
  }

  final psNames = namesSet.toList()..sort();
  return _ParsedBoundary(list, psNames);
}

class BoundaryService {
  static List<BoundaryFeature>? _features;
  static List<String>? _psNames;
  static bool _loading = false;

  static Future<void> _ensureLoaded() async {
    if (_features != null) return;
    if (_loading) {
      while (_loading) {
        await Future.delayed(const Duration(milliseconds: 80));
      }
      return;
    }
    _loading = true;
    try {
      final raw =
          await rootBundle.loadString('assets/geojson/boundary.geojson');
      // Off the UI thread - see _parseBoundaryJson for why this matters.
      final parsed = await compute(_parseBoundaryJson, raw);
      _features = parsed.features;
      _psNames = parsed.psNames;
    } catch (e) {
      print('BoundaryService error: $e');
      _features = [];
      _psNames = [];
    } finally {
      _loading = false;
    }
  }

  static Future<List<String>> getLocalGovNames() async {
    await _ensureLoaded();
    return List.from(_psNames ?? []);
  }

  /// Ray-casting point-in-polygon
  static bool _pointInRing(LatLng p, List<LatLng> ring) {
    bool inside = false;
    for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = ring[i].longitude, yi = ring[i].latitude;
      final xj = ring[j].longitude, yj = ring[j].latitude;
      final intersect = ((yi > p.latitude) != (yj > p.latitude)) &&
          (p.longitude <
              (xj - xi) * (p.latitude - yi) / (yj - yi + 1e-12) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  static bool pointInLocalGov(LatLng p, String psName) {
    final feats = _features;
    if (feats == null) return false;
    for (final f in feats) {
      if (f.psName != psName) continue;
      for (final ring in f.rings) {
        if (_pointInRing(p, ring)) return true;
      }
    }
    return false;
  }

  static Future<List<List<LatLng>>> getPolygonsFor(String psName) async {
    await _ensureLoaded();
    final rings = <List<LatLng>>[];
    for (final f in (_features ?? const <BoundaryFeature>[])) {
      if (f.psName == psName) rings.addAll(f.rings);
    }
    return rings;
  }

  /// Finds the GND-level feature (with full attributes) whose polygon
  /// contains [point]. If [restrictToPsName] is given, only that PS's
  /// GNDs are checked (much faster, and correct when a specific Local
  /// Gov boundary is what's on-screen).
  static Future<Map<String, dynamic>?> findFeatureAt(
    LatLng point, {
    String? restrictToPsName,
  }) async {
    await _ensureLoaded();
    for (final f in (_features ?? const <BoundaryFeature>[])) {
      if (restrictToPsName != null && f.psName != restrictToPsName) continue;
      for (final ring in f.rings) {
        if (_pointInRing(point, ring)) return f.props;
      }
    }
    return null;
  }
}
