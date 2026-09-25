import 'package:geolocator/geolocator.dart';
import '../models/poi.dart';

/// Finds nearby POIs, determines triggers, and prevents duplicate triggers
/// within the same walking session.
///
/// Responsibilities:
///   - Calculate distance from current position to every POI
///   - Determine whether a POI should fire (distance < radius AND not yet triggered)
///   - Maintain session-level triggered POI set (reset on new walk)
class PoiEngine {
  final Set<String> _triggeredPoiIds = {};

  /// IDs of POIs triggered in the current session (read-only view).
  Set<String> get triggeredPoiIds => Set.unmodifiable(_triggeredPoiIds);

  /// Reset triggered set — call when starting a new walk session.
  void resetSession() {
    _triggeredPoiIds.clear();
  }

  /// Returns the first POI that should trigger given [position], or null.
  ///
  /// A POI triggers when:
  ///   1. Distance to POI < trigger_radius
  ///   2. The POI has NOT already triggered in this session
  ///
  /// Returns the closest qualifying POI (in case multiple overlap).
  Poi? findTriggerablePoi(List<Poi> pois, double lat, double lng) {
    Poi? closest;
    double closestDistance = double.infinity;

    for (final poi in pois) {
      if (_triggeredPoiIds.contains(poi.id)) continue;

      final distance = Geolocator.distanceBetween(
        lat,
        lng,
        poi.latitude,
        poi.longitude,
      );

      if (distance < poi.triggerRadius && distance < closestDistance) {
        closest = poi;
        closestDistance = distance;
      }
    }

    return closest;
  }

  /// Mark a POI as triggered so it won't fire again this session.
  void markTriggered(String poiId) {
    _triggeredPoiIds.add(poiId);
  }

  /// Distance in metres from [lat],[lng] to [poi].
  double distanceTo(Poi poi, double lat, double lng) {
    return Geolocator.distanceBetween(lat, lng, poi.latitude, poi.longitude);
  }
}
