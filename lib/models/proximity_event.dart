/// Records a single proximity detection event during a walk.
class ProximityEvent {
  final String poiId;
  final String poiName;
  final double poiLat;
  final double poiLng;
  final double userLat;
  final double userLng;
  final double distanceM;
  final DateTime timestamp;

  const ProximityEvent({
    required this.poiId,
    required this.poiName,
    required this.poiLat,
    required this.poiLng,
    required this.userLat,
    required this.userLng,
    required this.distanceM,
    required this.timestamp,
  });

  @override
  String toString() =>
      'ProximityEvent($poiName, ${distanceM.toStringAsFixed(1)}m @ $timestamp)';
}
