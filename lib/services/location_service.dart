import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';

/// Obtains GPS coordinates and exposes a stream of position updates.
///
/// Responsibilities:
///   - Request location permission on first use
///   - Emit a continuous stream of [Position] while the walk is active
///   - Expose the most recent known position
class LocationService {
  /// On web: distanceFilter=0 because geolocator_web's skipWhile
  /// implementation has a bug with Chrome DevTools sensor simulation
  /// that silently drops all updates. We deduplicate manually instead.
  /// On native: distanceFilter=5 saves battery by only emitting when moved ≥5 m.
  static LocationSettings get _settings => kIsWeb
      ? const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        )
      : const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        );

  StreamSubscription<Position>? _subscription;
  final StreamController<Position> _controller =
      StreamController<Position>.broadcast();

  Position? _lastPosition;

  Stream<Position> get positionStream => _controller.stream;
  Position? get lastPosition => _lastPosition;

  /// Request permission and return true if granted.
  Future<bool> requestPermission() async {
    try {
      // isLocationServiceEnabled() always returns false on web (no OS GPS toggle).
      // On web we skip it and go straight to checking browser permission.
      if (!kIsWeb) {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled()
            .timeout(const Duration(seconds: 3));
        if (!serviceEnabled) return false;
      }

      LocationPermission permission = await Geolocator.checkPermission()
          .timeout(const Duration(seconds: 3));

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission()
            .timeout(const Duration(seconds: 10));
      }

      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (e) {
      print('Permission check error/timeout: $e');
      return false;
    }
  }

  /// Start streaming position updates.
  void start() {
    _subscription ??= Geolocator.getPositionStream(locationSettings: _settings)
        .listen((pos) {
      // Manual dedup on web (since distanceFilter=0 means every tick arrives)
      if (kIsWeb && _lastPosition != null) {
        if (_lastPosition!.latitude == pos.latitude &&
            _lastPosition!.longitude == pos.longitude) {
          return; // same coordinates, skip
        }
      }
      _lastPosition = pos;
      _controller.add(pos);
      print('📍 Position update: ${pos.latitude}, ${pos.longitude}');
    });
  }

  /// Stop streaming.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
