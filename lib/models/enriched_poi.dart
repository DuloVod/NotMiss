/// Research status for a POI.
enum ResearchStatus {
  notStarted,
  queued,
  inProgress,
  complete,
  partial,
  insufficientInformation,
  failed,
}

/// Research priority level.
enum ResearchPriority { high, medium, low }

/// A single verified fact about a POI.
class KeyFact {
  final String fact;
  final String? sourceUrl;
  final String confidence; // high, medium, low

  const KeyFact({
    required this.fact,
    this.sourceUrl,
    this.confidence = 'medium',
  });

  Map<String, dynamic> toJson() => {
    'fact': fact,
    'source_url': sourceUrl,
    'confidence': confidence,
  };

  factory KeyFact.fromJson(Map<String, dynamic> json) => KeyFact(
    fact: json['fact'] as String,
    sourceUrl: json['source_url'] as String?,
    confidence: json['confidence'] as String? ?? 'medium',
  );
}

/// Source information for research data.
class ResearchSource {
  final String url;
  final String title;
  final String type; // osm, wikidata, wikipedia, official, other

  const ResearchSource({
    required this.url,
    required this.title,
    required this.type,
  });

  Map<String, dynamic> toJson() => {
    'url': url,
    'title': title,
    'type': type,
  };

  factory ResearchSource.fromJson(Map<String, dynamic> json) => ResearchSource(
    url: json['url'] as String? ?? '',
    title: json['title'] as String? ?? '',
    type: json['type'] as String? ?? 'other',
  );
}

/// Enriched POI data with research results.
///
/// This is stored separately from the base [Poi] model and
/// linked by [poiId]. Contains facts, sources, category,
/// and research status metadata.
class EnrichedPoi {
  final String poiId;
  final String name;
  final String category;
  final double latitude;
  final double longitude;
  final ResearchStatus researchStatus;
  final String? shortDescription;
  final String? narrationText;
  final List<KeyFact> keyFacts;
  final String? interestingFact;
  final List<ResearchSource> sources;
  final List<String> uncertainties;
  final Map<String, String> osmTags;
  final String? wikidataId;
  final ResearchPriority priority;
  final DateTime? lastResearchedAt;
  final int schemaVersion;

  const EnrichedPoi({
    required this.poiId,
    required this.name,
    required this.category,
    required this.latitude,
    required this.longitude,
    this.researchStatus = ResearchStatus.notStarted,
    this.shortDescription,
    this.narrationText,
    this.keyFacts = const [],
    this.interestingFact,
    this.sources = const [],
    this.uncertainties = const [],
    this.osmTags = const {},
    this.wikidataId,
    this.priority = ResearchPriority.medium,
    this.lastResearchedAt,
    this.schemaVersion = 1,
  });

  /// Create a copy with updated fields.
  EnrichedPoi copyWith({
    String? name,
    double? latitude,
    double? longitude,
    ResearchStatus? researchStatus,
    String? shortDescription,
    String? narrationText,
    List<KeyFact>? keyFacts,
    String? interestingFact,
    List<ResearchSource>? sources,
    List<String>? uncertainties,
    Map<String, String>? osmTags,
    String? wikidataId,
    ResearchPriority? priority,
    DateTime? lastResearchedAt,
    String? category,
  }) {
    return EnrichedPoi(
      poiId: poiId,
      name: name ?? this.name,
      category: category ?? this.category,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      researchStatus: researchStatus ?? this.researchStatus,
      shortDescription: shortDescription ?? this.shortDescription,
      narrationText: narrationText ?? this.narrationText,
      keyFacts: keyFacts ?? this.keyFacts,
      interestingFact: interestingFact ?? this.interestingFact,
      sources: sources ?? this.sources,
      uncertainties: uncertainties ?? this.uncertainties,
      osmTags: osmTags ?? this.osmTags,
      wikidataId: wikidataId ?? this.wikidataId,
      priority: priority ?? this.priority,
      lastResearchedAt: lastResearchedAt ?? this.lastResearchedAt,
      schemaVersion: schemaVersion,
    );
  }

  /// Whether this POI has been fully researched and doesn't need more work.
  bool get isResearchComplete =>
      researchStatus == ResearchStatus.complete ||
      researchStatus == ResearchStatus.insufficientInformation;

  /// Whether this POI currently holds fallback/template content rather than verified research.
  bool get hasFallbackContent {
    final narr = narrationText ?? '';
    return narr.contains('Це одне з примітних місць на вашому маршруті. Зверніть увагу на його вигляд та деталі довкола!');
  }

  /// Content quality assessment.
  String get contentQuality {
    if (keyFacts.length >= 3 && shortDescription != null) return 'complete';
    if (keyFacts.isNotEmpty || shortDescription != null) return 'partial';
    return 'minimal';
  }

  Map<String, dynamic> toJson() => {
    'poi_id': poiId,
    'name': name,
    'category': category,
    'latitude': latitude,
    'longitude': longitude,
    'research_status': researchStatus.name,
    'short_description': shortDescription,
    'narration_text': narrationText,
    'key_facts': keyFacts.map((f) => f.toJson()).toList(),
    'interesting_fact': interestingFact,
    'sources': sources.map((s) => s.toJson()).toList(),
    'uncertainties': uncertainties,
    'osm_tags': osmTags,
    'wikidata_id': wikidataId,
    'priority': priority.name,
    'last_researched_at': lastResearchedAt?.toIso8601String(),
    'schema_version': schemaVersion,
  };

  factory EnrichedPoi.fromJson(Map<String, dynamic> json) {
    return EnrichedPoi(
      poiId: json['poi_id'] as String,
      name: json['name'] as String,
      category: json['category'] as String? ?? 'other',
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      researchStatus: ResearchStatus.values.firstWhere(
        (s) => s.name == json['research_status'],
        orElse: () => ResearchStatus.notStarted,
      ),
      shortDescription: json['short_description'] as String?,
      narrationText: json['narration_text'] as String?,
      keyFacts: (json['key_facts'] as List<dynamic>?)
              ?.map((f) => KeyFact.fromJson(f as Map<String, dynamic>))
              .toList() ??
          [],
      interestingFact: json['interesting_fact'] as String?,
      sources: (json['sources'] as List<dynamic>?)
              ?.map((s) => ResearchSource.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
      uncertainties: (json['uncertainties'] as List<dynamic>?)
              ?.map((u) => u.toString())
              .toList() ??
          [],
      osmTags: (json['osm_tags'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v.toString())) ??
          {},
      wikidataId: json['wikidata_id'] as String?,
      priority: ResearchPriority.values.firstWhere(
        (p) => p.name == json['priority'],
        orElse: () => ResearchPriority.medium,
      ),
      lastResearchedAt: json['last_researched_at'] != null
          ? DateTime.tryParse(json['last_researched_at'] as String)
          : null,
      schemaVersion: json['schema_version'] as int? ?? 1,
    );
  }

  @override
  String toString() => 'EnrichedPoi($poiId, $name, $category, $researchStatus)';
}
