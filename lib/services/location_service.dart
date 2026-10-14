import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' show exp;
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:geolocator/geolocator.dart';

/// Obtains GPS coordinates and exposes a stream of position updates.
///
/// Improvements over the raw Geolocator stream:
///   - Requests `bestForNavigation` accuracy on Android (uses all sensors)
///   - Filters out positions with accuracy worse than [_maxAccuracyM]
///   - Applies a lightweight Kalman-style smoothing filter to reduce GPS jitter
///   - Skips duplicate positions (same lat/lng) on web
class LocationService {
  /// Worst accuracy we accept. Positions with accuracy > this are discarded.
  static const double _maxAccuracyM = 40.0;

  static LocationSettings get _settings {
    if (kIsWeb) {
      return const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      );
    }
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 500),
        forceLocationManager: false,
      );
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        activityType: ActivityType.fitness,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
        pauseLocationUpdatesAutomatically: false,
      );
    }
    // Fallback for other platforms
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );
  }

  StreamSubscription<Position>? _subscription;
  final StreamController<Position> _controller =
      StreamController<Position>.broadcast();

  Position? _lastPosition;

  // Kalman state — smoothed lat/lng estimate
  double? _smoothLat;
  double? _smoothLng;

  Stream<Position> get positionStream => _controller.stream;
  Position? get lastPosition => _lastPosition;

  /// Request permission and return true if granted.
  Future<bool> requestPermission() async {
    try {
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
      return false;
    }
  }

  /// Start streaming position updates.
  void start() {
    _subscription ??=
        Geolocator.getPositionStream(locationSettings: _settings).listen((pos) {
      // ── 1. Accuracy gate ───────────────────────────────────────────────
      if (!kIsWeb && pos.accuracy > _maxAccuracyM) {
        // Too inaccurate — discard and wait for a better fix
        return;
      }

      // ── 2. Deduplicate (web only) ──────────────────────────────────────
      if (kIsWeb && _lastPosition != null) {
        if (_lastPosition!.latitude == pos.latitude &&
            _lastPosition!.longitude == pos.longitude) {
          return;
        }
      }

      // ── 3. Kalman-style smoothing (native only) ─────────────────────────
      // On first fix, initialise the smoothed state directly.
      if (!kIsWeb) {
        if (_smoothLat == null) {
          _smoothLat = pos.latitude;
          _smoothLng = pos.longitude;
        } else {
          // Adaptive gain: trust the new measurement more when accuracy is good
          // and less when it's poor. Maps accuracy 0→40 to gain 0.85→0.35.
          final adaptiveGain =
              _adaptiveGain(pos.accuracy, min: 0.35, max: 0.85);
          _smoothLat = _smoothLat! + adaptiveGain * (pos.latitude - _smoothLat!);
          _smoothLng =
              _smoothLng! + adaptiveGain * (pos.longitude - _smoothLng!);
        }

        // Re-package as a Position with the smoothed coordinates.
        // We keep the original accuracy/altitude/speed fields from the fix.
        pos = Position(
          latitude: _smoothLat!,
          longitude: _smoothLng!,
          timestamp: pos.timestamp,
          accuracy: pos.accuracy,
          altitude: pos.altitude,
          altitudeAccuracy: pos.altitudeAccuracy,
          heading: pos.heading,
          headingAccuracy: pos.headingAccuracy,
          speed: pos.speed,
          speedAccuracy: pos.speedAccuracy,
        );
      }

      _lastPosition = pos;
      _controller.add(pos);
    }, onError: (error) {
      debugPrint('[LocationService] Stream error: $error');
    });
  }

  /// Stop streaming.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
    // Reset smoothing state so the next walk starts fresh
    _smoothLat = null;
    _smoothLng = null;
    _lastPosition = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  /// Maps accuracy value (meters) to a Kalman gain in [min, max].
  /// Low accuracy (high meters) → low gain (trust old estimate more).
  /// High accuracy (low meters) → high gain (trust new measurement more).
  double _adaptiveGain(double accuracyM,
      {required double min, required double max}) {
    // Exponential decay: gain = max * exp(-k * accuracyM)
    // Calibrated so that at accuracyM=5 → ~0.80, at 40 → ~0.37
    const k = 0.025;
    final gain = max * exp(-k * accuracyM);
    return gain.clamp(min, max);
  }
}
