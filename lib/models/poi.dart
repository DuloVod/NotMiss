class Poi {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final double triggerRadius; // metres
  final String shortDescription;
  final List<String> facts;
  final String narrationText; // static fallback; used before AI generates
  final List<String> sources;

  const Poi({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.triggerRadius,
    required this.shortDescription,
    required this.facts,
    required this.narrationText,
    required this.sources,
  });

  factory Poi.fromJson(Map<String, dynamic> json) {
    return Poi(
      id: json['id'] as String,
      name: json['name'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      triggerRadius: (json['trigger_radius'] as num).toDouble(),
      shortDescription: json['short_description'] as String,
      facts: List<String>.from(json['facts'] as List),
      narrationText: json['narration_text'] as String,
      sources: List<String>.from(json['sources'] as List),
    );
  }
}
