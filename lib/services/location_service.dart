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
  static const LocationSettings _settings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 5, // emit only if moved ≥5 m
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
      _lastPosition = pos;
      _controller.add(pos);
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
