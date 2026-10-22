import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import '../models/road_model.dart';
import 'boundary_service.dart';

// Small isolate-safe (no dependency on any other class's static/cached
// state) ray-casting point-in-polygon test, used only inside the
// background-isolate matching function below.
bool _rayCastPointInRing(LatLng p, List<LatLng> ring) {
  bool inside = false;
  for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i].longitude, yi = ring[i].latitude;
    final xj = ring[j].longitude, yj = ring[j].latitude;
    final intersect = ((yi > p.latitude) != (yj > p.latitude)) &&
        (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi + 1e-12) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}

// Parses the roads GeoJSON (~28 MB, tens of thousands of features) into
// RoadModels. Runs on a background isolate via compute() - decoding a file
// this size synchronously on the UI thread would freeze the whole app for
// several seconds (and risk an ANR / OOM) on a lower-end Android 10 phone.
List<RoadModel> _parseRoadsJson(String raw) {
  final data = json.decode(raw) as Map<String, dynamic>;
  final features = data['features'] as List;
  return features
      .map((f) => RoadModel.fromFeature(f as Map<String, dynamic>))
      .toList();
}

class _NearbyRoadsArgs {
  final List<RoadModel> roads;
  final List<LatLng> trackPoints;
  final double radiusMeters;
  _NearbyRoadsArgs(this.roads, this.trackPoints, this.radiusMeters);
}

// The actual nearest-road matching loop, run off the UI thread. With tens
// of thousands of road features this nested loop is real CPU work, not
// just I/O, so it needs to be off the main isolate too, not just the JSON
// parse - otherwise the UI would still stutter every time this search runs.
List<RoadModel> _findNearbyRoadsSync(_NearbyRoadsArgs args) {
  final roads = args.roads;
  final trackPoints = args.trackPoints;
  final radiusMeters = args.radiusMeters;
  if (trackPoints.isEmpty || roads.isEmpty) return [];

  const distance = Distance();
  final matched = <int>{};
  final result = <RoadModel>[];

  final samples = <LatLng>[];
  for (int i = 0; i < trackPoints.length; i += 2) {
    samples.add(trackPoints[i]);
  }
  if (samples.isEmpty) samples.add(trackPoints.last);

  for (final road in roads) {
    if (road.coordinates.length < 2) continue;
    final id = road.id.toInt();
    if (matched.contains(id)) continue;

    bool near = false;
    outer:
    for (final sample in samples) {
      for (final c in road.coordinates) {
        final d = distance.as(LengthUnit.Meter, sample, LatLng(c[1], c[0]));
        if (d <= radiusMeters) {
          near = true;
          break outer;
        }
      }
    }

    if (near) {
      matched.add(id);
      result.add(road);
    }
  }

  result.sort((a, b) => a.rName.compareTo(b.rName));
  return result;
}

class _LocalGovRoadsArgs {
  final List<RoadModel> roads;
  final List<List<LatLng>> boundaryRings;
  _LocalGovRoadsArgs(this.roads, this.boundaryRings);
}

List<RoadModel> _findRoadsInLocalGovSync(_LocalGovRoadsArgs args) {
  final result = <RoadModel>[];
  for (final road in args.roads) {
    if (road.coordinates.isEmpty) continue;
    final samples = <LatLng>[];
    for (int i = 0; i < road.coordinates.length; i += 4) {
      final c = road.coordinates[i];
      samples.add(LatLng(c[1], c[0]));
    }
    if (samples.isEmpty) {
      final c = road.coordinates.first;
      samples.add(LatLng(c[1], c[0]));
    }

    bool matchedRoad = false;
    for (final p in samples) {
      for (final ring in args.boundaryRings) {
        if (_rayCastPointInRing(p, ring)) {
          matchedRoad = true;
          break;
        }
      }
      if (matchedRoad) break;
    }
    if (matchedRoad) result.add(road);
  }

  result.sort((a, b) => a.rName.compareTo(b.rName));
  return result;
}

class RoadService {
  static List<RoadModel>? _roads;
  static bool _loading = false;

  static Future<List<RoadModel>> loadRoads() async {
    if (_roads != null) return _roads!;
    if (_loading) {
      while (_loading) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return _roads ?? [];
    }

    _loading = true;
    try {
      final raw = await rootBundle
          .loadString('assets/geojson/Road_simplified.geojson');
      // Off the UI thread - see _parseRoadsJson for why this matters.
      _roads = await compute(_parseRoadsJson, raw);
      return _roads!;
    } catch (e) {
      print('RoadService load error: $e');
      _roads = [];
      return _roads!;
    } finally {
      _loading = false;
    }
  }

  /// Nearby roads to track points (default 90 m).
  static Future<List<RoadModel>> findNearbyRoads(
    List<LatLng> trackPoints, {
    double radiusMeters = 90,
  }) async {
    final roads = await loadRoads();
    if (trackPoints.isEmpty || roads.isEmpty) return [];
    return compute(
      _findNearbyRoadsSync,
      _NearbyRoadsArgs(roads, trackPoints, radiusMeters),
    );
  }

  /// All roads that fall inside a given Local Government (PS / UC / MC).
  static Future<List<RoadModel>> findRoadsInLocalGov(String psName) async {
    final rings = await BoundaryService.getPolygonsFor(psName);
    final roads = await loadRoads();
    if (roads.isEmpty || rings.isEmpty) return [];
    return compute(
      _findRoadsInLocalGovSync,
      _LocalGovRoadsArgs(roads, rings),
    );
  }

  static List<LatLng> roadToLatLngs(RoadModel road) {
    return road.coordinates.map((c) => LatLng(c[1], c[0])).toList();
  }
}
