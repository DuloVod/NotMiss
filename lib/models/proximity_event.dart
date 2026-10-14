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

  factory ProximityEvent.fromJson(Map<String, dynamic> json) {
    return ProximityEvent(
      poiId: json['poi_id'] as String? ?? '',
      poiName: json['poi_name'] as String? ?? '',
      poiLat: (json['poi_lat'] as num?)?.toDouble() ?? 0.0,
      poiLng: (json['poi_lng'] as num?)?.toDouble() ?? 0.0,
      userLat: (json['user_lat'] as num?)?.toDouble() ?? 0.0,
      userLng: (json['user_lng'] as num?)?.toDouble() ?? 0.0,
      distanceM: (json['distance_m'] as num?)?.toDouble() ?? 0.0,
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'poi_id': poiId,
        'poi_name': poiName,
        'poi_lat': poiLat,
        'poi_lng': poiLng,
        'user_lat': userLat,
        'user_lng': userLng,
        'distance_m': distanceM,
        'timestamp': timestamp.toIso8601String(),
      };

  @override
  String toString() =>
      'ProximityEvent($poiName, ${distanceM.toStringAsFixed(1)}m @ $timestamp)';
}
