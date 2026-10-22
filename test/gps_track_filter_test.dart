import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:nwp_gis_app/services/gps_track_filter.dart';

// Run with:  flutter test test/gps_track_filter_test.dart

const double _lat0 = 7.4863;
const double _lng0 = 80.3636;
const double _mPerDegLat = 111132.92;
final double _mPerDegLng = 111320.0 * math.cos(_lat0 * math.pi / 180.0);
final DateTime _t0 = DateTime.utc(2026, 1, 1, 0, 0, 0);
const Distance _dist = Distance();

double _meters(LatLng a, LatLng b) => _dist.as(LengthUnit.Meter, a, b);

Position _pos({
  required double eastM,
  required double northM,
  required int seconds,
  double acc = 5.0,
  double speed = 0.0,
  double heading = 0.0,
}) {
  return Position(
    longitude: _lng0 + eastM / _mPerDegLng,
    latitude: _lat0 + northM / _mPerDegLat,
    timestamp: _t0.add(Duration(seconds: seconds)),
    accuracy: acc,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: heading,
    headingAccuracy: 8,
    speed: speed,
    speedAccuracy: 0.3,
  );
}

/// Time-correlated noise (like real GPS wander), deterministic.
class _Noise {
  final math.Random _rng;
  final double sigma;
  final double phi;
  double _x = 0.0;
  _Noise(int seed, this.sigma, {this.phi = 0.9}) : _rng = math.Random(seed);

  double _gauss() {
    final u1 = 1.0 - _rng.nextDouble();
    final u2 = _rng.nextDouble();
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2);
  }

  double next() {
    _x = phi * _x + sigma * math.sqrt(1 - phi * phi) * _gauss();
    return _x;
  }
}

/// Mirrors the recording rule in main.dart.
double _recordedLength(
  GpsTrackFilter filter,
  List<Position> fixes, {
  bool useFilter = true,
}) {
  final List<LatLng> rec = [];
  double total = 0.0;
  for (final p in fixes) {
    LatLng pt;
    double acc;
    bool ok;
    if (useFilter) {
      final f = filter.process(p);
      if (f == null) continue;
      pt = f.smoothed;
      acc = f.accuracy;
      ok = f.recordable;
    } else {
      pt = LatLng(p.latitude, p.longitude);
      acc = p.accuracy;
      ok = acc <= 20.0;
    }
    if (!ok) continue;
    if (rec.isNotEmpty) {
      final d = _meters(rec.last, pt);
      if (d < math.max(3.0, acc * 0.5)) continue;
      total += d;
    }
    rec.add(pt);
  }
  return total;
}

void main() {
  test('standing still: filtered track gains almost no phantom distance', () {
    final nE = _Noise(1, 3.0);
    final nN = _Noise(2, 3.0);
    final fixes = <Position>[
      for (int s = 0; s < 600; s++)
        _pos(eastM: nE.next(), northM: nN.next(), seconds: s),
    ];

    // Original behaviour: every fix recorded.
    double rawLen = 0.0;
    for (int i = 1; i < fixes.length; i++) {
      rawLen += _meters(
        LatLng(fixes[i - 1].latitude, fixes[i - 1].longitude),
        LatLng(fixes[i].latitude, fixes[i].longitude),
      );
    }

    final filteredLen = _recordedLength(GpsTrackFilter(), fixes);
    expect(rawLen, greaterThan(800.0)); // raw jitter really is large
    expect(filteredLen, lessThan(150.0));
    expect(filteredLen, lessThan(rawLen / 5));
  });

  test('walking a 100 m square: measured length close to the truth', () {
    final nE = _Noise(3, 3.0);
    final nN = _Noise(4, 3.0);
    final fixes = <Position>[];
    double e = 0, n = 0;
    int t = 0;
    const speed = 1.4;
    // headings: east, north, west, south
    const legs = [
      [1.0, 0.0, 90.0],
      [0.0, 1.0, 0.0],
      [-1.0, 0.0, 270.0],
      [0.0, -1.0, 180.0],
    ];
    for (final leg in legs) {
      for (int i = 0; i < 71; i++) {
        fixes.add(
          _pos(
            eastM: e + nE.next(),
            northM: n + nN.next(),
            seconds: t,
            speed: speed,
            heading: leg[2],
          ),
        );
        e += leg[0] * speed;
        n += leg[1] * speed;
        t += 1;
      }
    }
    const trueLen = 71 * 4 * speed;
    final len = _recordedLength(GpsTrackFilter(), fixes);
    expect(len, inInclusiveRange(trueLen * 0.92, trueLen * 1.08));
  });

  test('stale, duplicate and out-of-order fixes are ignored', () {
    final f = GpsTrackFilter();
    expect(f.process(_pos(eastM: 0, northM: 0, seconds: 10)), isNotNull);
    expect(f.process(_pos(eastM: 0, northM: 0, seconds: 10)), isNull);
    expect(f.process(_pos(eastM: 0, northM: 0, seconds: 5)), isNull);
    expect(f.process(_pos(eastM: 0, northM: 0, seconds: 11)), isNotNull);
  });

  test('a single impossible position jump is rejected', () {
    final f = GpsTrackFilter();
    for (int s = 0; s < 10; s++) {
      expect(f.process(_pos(eastM: 1.4 * s, northM: 0, seconds: s)), isNotNull);
    }
    // 300 m away one second later, claiming 5 m accuracy.
    expect(f.process(_pos(eastM: 300, northM: 0, seconds: 10)), isNull);
    // Normal fix afterwards is accepted again.
    expect(f.process(_pos(eastM: 14.0, northM: 0, seconds: 11)), isNotNull);
  });

  test('persistent relocation is accepted after 4 consecutive jumps', () {
    final f = GpsTrackFilter();
    for (int s = 0; s < 5; s++) {
      f.process(_pos(eastM: 0, northM: 0, seconds: s));
    }
    FilteredFix? last;
    for (int s = 5; s < 9; s++) {
      last = f.process(_pos(eastM: 500, northM: 0, seconds: s));
    }
    expect(last, isNotNull);
    expect(
      _meters(last!.smoothed, LatLng(_lat0, _lng0 + 500 / _mPerDegLng)),
      lessThan(5.0),
    );
  });

  test('poor-accuracy fixes are not recordable', () {
    final f = GpsTrackFilter(maxAccuracyMeters: 20.0);
    final good = f.process(_pos(eastM: 0, northM: 0, seconds: 0, acc: 5));
    final poor = f.process(_pos(eastM: 1, northM: 0, seconds: 1, acc: 45));
    expect(good!.recordable, isTrue);
    expect(poor, isNotNull);
    expect(poor!.recordable, isFalse);
  });

  test('reset() forgets previous state', () {
    final f = GpsTrackFilter();
    f.process(_pos(eastM: 0, northM: 0, seconds: 100));
    f.reset();
    // An earlier timestamp is fine again after a reset.
    expect(f.process(_pos(eastM: 0, northM: 0, seconds: 1)), isNotNull);
  });
}
