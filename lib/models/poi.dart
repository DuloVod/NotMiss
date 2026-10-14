class PoiSource {
  final String title;
  final String url;

  const PoiSource({required this.title, required this.url});

  factory PoiSource.fromJson(Map<String, dynamic> json) {
    return PoiSource(
      title: json['title'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
      };
}

class Poi {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final double triggerRadius; // metres
  final String shortDescription;
  final List<String> facts;
  final String narrationText; // narration_idea_uk or narration_text
  final List<PoiSource> sources;
  final String confidence;
  final String? wikidataId;
  final Map<String, String>? osmTags;

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
    this.confidence = 'high',
    this.wikidataId,
    this.osmTags,
  });

  factory Poi.fromJson(Map<String, dynamic> json) {
    // Support both old format (name, trigger_radius, facts, narration_text)
    // and new format (name_uk, trigger_radius_m, facts_uk, narration_idea_uk)
    final name = (json['name_uk'] ?? json['name'] ?? '') as String;
    final triggerRadius =
        ((json['trigger_radius_m'] ?? json['trigger_radius'] ?? 70) as num)
            .toDouble();
    final shortDescription =
        (json['short_description_uk'] ?? json['short_description'] ?? '') as String;
    final facts = List<String>.from(
        (json['facts_uk'] ?? json['facts'] ?? []) as List);
    // Use narration_idea_uk as the narration text for AI prompting;
    // fall back to narration_text if present.
    final narrationText =
        (json['narration_idea_uk'] ?? json['narration_text'] ?? '') as String;

    // Sources can be a list of objects {title, url} or a list of strings
    List<PoiSource> sources = [];
    final rawSources = json['sources'];
    if (rawSources is List) {
      for (final s in rawSources) {
        if (s is Map<String, dynamic>) {
          sources.add(PoiSource.fromJson(s));
        } else if (s is String) {
          sources.add(PoiSource(title: s, url: ''));
        }
      }
    }

    // Restore OSM tags if present
    Map<String, String>? osmTags;
    final rawTags = json['osmTags'] as Map<String, dynamic>?;
    if (rawTags != null) {
      osmTags = rawTags.map((k, v) => MapEntry(k, v.toString()));
    }

    return Poi(
      id: json['id'].toString(), // Handle both String and int IDs (OSM uses int)
      name: name,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      triggerRadius: triggerRadius,
      shortDescription: shortDescription,
      facts: facts,
      narrationText: narrationText,
      sources: sources,
      confidence: (json['confidence'] as String?) ?? 'high',
      wikidataId: json['wikidataId'] as String? ?? json['wikidata_id'] as String?,
      osmTags: osmTags,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'trigger_radius_m': triggerRadius,
        'short_description_uk': shortDescription,
        'facts_uk': facts,
        'narration_idea_uk': narrationText,
        'sources': sources.map((s) => s.toJson()).toList(),
        'confidence': confidence,
        'wikidata_id': wikidataId,
        'osm_tags': osmTags,
      };

  Poi copyWith({
    String? id,
    String? name,
    double? latitude,
    double? longitude,
    double? triggerRadius,
    String? shortDescription,
    List<String>? facts,
    String? narrationText,
    List<PoiSource>? sources,
    String? confidence,
    String? wikidataId,
    Map<String, String>? osmTags,
  }) {
    return Poi(
      id: id ?? this.id,
      name: name ?? this.name,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      triggerRadius: triggerRadius ?? this.triggerRadius,
      shortDescription: shortDescription ?? this.shortDescription,
      facts: facts ?? this.facts,
      narrationText: narrationText ?? this.narrationText,
      sources: sources ?? this.sources,
      confidence: confidence ?? this.confidence,
      wikidataId: wikidataId ?? this.wikidataId,
      osmTags: osmTags ?? this.osmTags,
    );
  }
}
