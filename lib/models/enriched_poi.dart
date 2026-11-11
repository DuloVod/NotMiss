import '../l10n/app_lang.dart';
import '../services/text_quality.dart';

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
  /// Content generated before this version was not checked against sources: it is never shown
  /// and gets researched again.
  static const int currentSchema = 2;

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

  /// Text of all sources used for this place (basis for AI answers about it).
  final String? sourceMaterial;

  /// Language of the stored story and facts ([AppLang.code]). Content in another language than
  /// the current one is not shown and is researched again.
  final String contentLang;

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
    this.schemaVersion = currentSchema,
    this.sourceMaterial,
    this.contentLang = 'uk',
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
    int? schemaVersion,
    String? sourceMaterial,
    String? contentLang,
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
      schemaVersion: schemaVersion ?? this.schemaVersion,
      sourceMaterial: sourceMaterial ?? this.sourceMaterial,
      contentLang: contentLang ?? this.contentLang,
    );
  }

  /// Written by an older version of the app, without verification against sources.
  bool get isOutdated => schemaVersion < currentSchema || contentLang != L.lang.code;

  /// Whether this POI has been fully researched and doesn't need more work.
  bool get isResearchComplete =>
      researchStatus == ResearchStatus.complete ||
      researchStatus == ResearchStatus.insufficientInformation;

  /// Said when no source knows anything about a place: honesty instead of invention.
  static const String noVerifiedInfoPhraseUk = 'Перевірених відомостей про це місце поки немає';
  static const String noVerifiedInfoPhraseEn = 'There is no verified information about this place yet';
  static String get noVerifiedInfoPhrase => L.en ? noVerifiedInfoPhraseEn : noVerifiedInfoPhraseUk;

  /// The text is the honest "nothing is known" line: such a place is shown, not narrated.
  static bool hasNoVerifiedInfo(String? text) =>
      text != null && (text.contains(noVerifiedInfoPhraseUk) || text.contains(noVerifiedInfoPhraseEn));

  /// No source knows anything about this place: it is marked on the map but not narrated.
  bool get isSilent =>
      !isOutdated &&
      (researchStatus == ResearchStatus.insufficientInformation || hasNoVerifiedInfo(narrationText));

  /// Whether this POI currently holds fallback/template content rather than verified research.
  bool get hasFallbackContent {
    if (isOutdated) return true;
    final narr = narrationText ?? '';
    if (hasNoVerifiedInfo(narr)) return true;
    if (narr.contains('Це одне з примітних місць на вашому маршруті') ||
        narr.contains('Зверніть увагу на його вигляд та деталі довкола') ||
        narr.contains('Зверніть увагу на архітектурні деталі та атмосферу довкола!')) {
      return true;
    }
    // Leaked prompt text, fragments, non-Ukrainian or cut-off narration must be regenerated.
    if (TextQuality.isBadStoredNarration(narr)) return true;
    if (keyFacts.isNotEmpty &&
        keyFacts.every((f) =>
            f.fact.contains('належить до категорії') ||
            f.fact.contains('відкритий для огляду') ||
            f.fact.contains('відкрито для огляду') ||
            f.fact.contains('примітне місце на вашому маршруті'))) {
      return true;
    }
    return false;
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
    'source_material': sourceMaterial,
    'content_lang': contentLang,
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
      sourceMaterial: json['source_material'] as String?,
      contentLang: json['content_lang'] as String? ?? 'uk',
    );
  }

  @override
  String toString() => 'EnrichedPoi($poiId, $name, $category, $researchStatus)';
}
