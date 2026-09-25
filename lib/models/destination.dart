import 'poi.dart';

class Destination {
  final String id;
  final String name;
  final double centerLatitude;
  final double centerLongitude;
  final double defaultZoom;
  final List<Poi> pois;

  const Destination({
    required this.id,
    required this.name,
    required this.centerLatitude,
    required this.centerLongitude,
    required this.defaultZoom,
    required this.pois,
  });

  factory Destination.fromJson(Map<String, dynamic> json) {
    return Destination(
      id: json['id'] as String,
      name: json['name'] as String,
      centerLatitude: (json['center_latitude'] as num).toDouble(),
      centerLongitude: (json['center_longitude'] as num).toDouble(),
      defaultZoom: (json['default_zoom'] as num? ?? 16).toDouble(),
      pois: (json['pois'] as List)
          .map((p) => Poi.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }
}
