import 'dart:async';
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
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
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
