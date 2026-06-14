import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:position_core/position_core.dart';

/// Where a device's position comes from — the one swappable layer that isolates
/// phone-only concerns (real fixes, permissions) from the rest of the app.
abstract class LocationSource {
  /// A one-shot current fix, or null if unavailable.
  Future<Position?> current();

  /// A stream of fixes that emits as the position changes — what drives
  /// automatic publishing.
  Stream<Position> positions();
}

/// Web / tests: a fixed coordinate, changed by [set] (e.g. tapping the map).
/// A browser posting this is conceptually identical to a phone posting GPS.
class ManualLocationSource implements LocationSource {
  Position value;
  final _ctrl = StreamController<Position>.broadcast();

  ManualLocationSource([this.value = const Position(48.8566, 2.3522, 0)]);

  /// Move to a new point and emit it to listeners.
  void set(double lat, double lon) {
    value = Position(lat, lon, _now());
    _ctrl.add(value);
  }

  @override
  Future<Position?> current() async => Position(value.lat, value.lon, _now());

  @override
  Stream<Position> positions() => _ctrl.stream;
}

/// Mobile: real fixes via the OS location service — one-shot and a movement
/// stream (emits when you move past [_distanceFilter] metres).
class GeolocatorLocationSource implements LocationSource {
  static const _distanceFilter = 15; // metres

  Future<bool> _ensurePermission() async {
    var perm = await geo.Geolocator.checkPermission();
    if (perm == geo.LocationPermission.denied) {
      perm = await geo.Geolocator.requestPermission();
    }
    return perm != geo.LocationPermission.denied &&
        perm != geo.LocationPermission.deniedForever;
  }

  @override
  Future<Position?> current() async {
    if (!await _ensurePermission()) return null;
    final p = await geo.Geolocator.getCurrentPosition();
    return Position(p.latitude, p.longitude, _now());
  }

  @override
  Stream<Position> positions() async* {
    if (!await _ensurePermission()) return;
    yield* geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(distanceFilter: _distanceFilter),
    ).map((p) => Position(p.latitude, p.longitude, _now()));
  }
}

LocationSource createLocationSource() {
  if (kIsWeb) return ManualLocationSource();
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return GeolocatorLocationSource();
    default:
      return ManualLocationSource();
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
