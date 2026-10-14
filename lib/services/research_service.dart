import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import '../models/poi.dart';
import '../models/enriched_poi.dart';
import 'poi_category_service.dart';
import 'poi_cache_service.dart';
import 'research_queue.dart';
import 'wikidata_service.dart';
import 'wikipedia_service.dart';
import 'ai_service.dart';

/// Orchestrates the research pipeline for POIs.
///
/// 1. Takes basic POIs from Overpass.
/// 2. Categorizes them.
/// 3. Checks the cache.
/// 4. Enqueues incomplete POIs for research.
/// 5. Sequentially gathers data (OSM -> Wikidata -> Wikipedia).
/// 6. Caches results.
class ResearchService {
  final PoiCategoryService _categoryService;
  final PoiCacheService _cacheService;
  final ResearchQueue _queue;
  final WikidataService _wikidataService;
  final WikipediaService _wikipediaService;
  final AiService _aiService;

  ResearchService({
    required PoiCategoryService categoryService,
    required PoiCacheService cacheService,
    required ResearchQueue queue,
    required WikidataService wikidataService,
    required WikipediaService wikipediaService,
    required AiService aiService,
  })  : _categoryService = categoryService,
        _cacheService = cacheService,
        _queue = queue,
        _wikidataService = wikidataService,
        _wikipediaService = wikipediaService,
        _aiService = aiService {
    _queue.onProcess = _processResearchTask;
  }

  /// Callback when a POI's research status or content is updated.
  void Function(EnrichedPoi enriched)? onPoiUpdated;

  int get pendingResearchCount => _queue.pendingCount;
  int get activeResearchCount => _queue.activeCount;
  int getQueuePosition(String poiId) => _queue.getQueuePosition(poiId);

  /// Expose the underlying cache lookup.
  EnrichedPoi? getEnrichedData(String poiId) => _cacheService.get(poiId);

  /// Initialize the cache. Call once at app startup.
  Future<void> init() async {
    await _cacheService.init();
  }

  /// Release resources. Call when the service is no longer needed.
  void dispose() {
    _queue.clear();
    _cacheService.dispose();
  }

  /// Process new POIs discovered by Overpass.
  void processDiscoveredPois(List<Poi> pois) {
    for (final poi in pois) {
      // Create initial EnrichedPoi if it doesn't exist
      var enriched = _cacheService.get(poi.id);
      if (enriched == null) {
        final category = _categoryService.categorize(poi.osmTags ?? {});
        final priority = _categoryService.determinePriority(poi.osmTags ?? {}, category);

        enriched = EnrichedPoi(
          poiId: poi.id,
          name: poi.name,
          category: category,
          latitude: poi.latitude,
          longitude: poi.longitude,
          researchStatus: ResearchStatus.notStarted,
          osmTags: poi.osmTags ?? {},
          wikidataId: poi.wikidataId,
          priority: priority,
        );
        _cacheService.put(enriched);
      }

      // Enqueue if needs research
      if (_cacheService.needsResearch(poi.id)) {
        _queue.enqueue(poi.id, enriched.priority);
      }
    }
  }

  final Set<String> _bumpedPois = {};

  /// Bumps a specific POI to the highest priority in the research queue.
  /// Used when the user physically approaches an unresearched POI.
  void prioritizePoi(String poiId) {
    if (_cacheService.needsResearch(poiId)) {
      _bumpedPois.add(poiId);
      _queue.enqueue(poiId, ResearchPriority.high, bump: true);
    }
  }

  /// Forces immediate research of a POI, executing it right away.
  Future<void> researchImmediately(String poiId, {Poi? poi}) async {
    var enriched = _cacheService.get(poiId);
    if (enriched == null && poi != null) {
      final category = _categoryService.categorize(poi.osmTags ?? {});
      enriched = EnrichedPoi(
        poiId: poi.id,
        name: poi.name,
        category: category,
        latitude: poi.latitude,
        longitude: poi.longitude,
        researchStatus: ResearchStatus.notStarted,
        osmTags: poi.osmTags ?? {},
        wikidataId: poi.wikidataId,
        priority: ResearchPriority.high,
      );
      await _cacheService.put(enriched);
      onPoiUpdated?.call(enriched);
    }
    await _processResearchTask(poiId);
  }

  /// The core research workflow executed by the queue.
  Future<void> _processResearchTask(String poiId) async {
    final enriched = _cacheService.get(poiId);
    if (enriched == null) return;
    
    // Mark in progress
    final inProg = enriched.copyWith(
      researchStatus: ResearchStatus.inProgress,
    );
    await _cacheService.put(inProg);
    onPoiUpdated?.call(inProg);

    debugPrint('[ResearchService] Starting research for ${enriched.name} ($poiId)');

    try {
      final facts = <KeyFact>[...enriched.keyFacts];
      final sources = <ResearchSource>[...enriched.sources];
      String? shortDesc = enriched.shortDescription;
      String? wikidataId = enriched.wikidataId;

      // STEP 1: Wikidata
      if (wikidataId != null && wikidataId.isNotEmpty) {
        final wikiData = await _wikidataService.fetchById(wikidataId);
        if (wikiData != null) {
          if (wikiData.inception != null) {
            facts.add(KeyFact(
              fact: 'Створено/засновано: ${wikiData.inception}',
              sourceUrl: 'https://www.wikidata.org/wiki/$wikidataId',
              confidence: 'high',
            ));
          }
          if (wikiData.architect != null) {
            facts.add(KeyFact(
              fact: 'Архітектор/творець: ${wikiData.architect}',
              sourceUrl: 'https://www.wikidata.org/wiki/$wikidataId',
              confidence: 'high',
            ));
          }
          if (shortDesc == null || shortDesc.isEmpty) {
            shortDesc = wikiData.description;
          }
          
          if (!sources.any((s) => s.type == 'wikidata')) {
            sources.add(ResearchSource(
              url: 'https://www.wikidata.org/wiki/$wikidataId',
              title: 'Wikidata (${wikiData.label ?? wikidataId})',
              type: 'wikidata',
            ));
          }
          
          // STEP 2: Wikipedia (if we have a linked article)
          if (wikiData.wikipediaTitle != null && wikiData.wikipediaLang != null) {
            final wikiArticle = await _wikipediaService.fetchSummary(
              wikiData.wikipediaTitle!,
              lang: wikiData.wikipediaLang!,
            );
            if (wikiArticle != null) {
              if (shortDesc == null || shortDesc.isEmpty) {
                shortDesc = wikiArticle.description ?? _firstSentence(wikiArticle.extract);
              }
              facts.add(KeyFact(
                fact: _truncate(wikiArticle.extract, 150),
                sourceUrl: wikiArticle.url,
                confidence: 'high',
              ));
              
              if (!sources.any((s) => s.type == 'wikipedia')) {
                sources.add(ResearchSource(
                  url: wikiArticle.url,
                  title: 'Wikipedia (${wikiArticle.title})',
                  type: 'wikipedia',
                ));
              }
            }
          }
        }
      }

      String? narrationText = enriched.narrationText;

      // Filter out trivial raw OSM tag strings (like "library" or "artwork")
      bool isTrivial(String? s) {
        if (s == null || s.trim().isEmpty) return true;
        final trimmed = s.trim().toLowerCase();
        const trivialOsmValues = {
          'library', 'artwork', 'monument', 'fountain', 'viewpoint',
          'museum', 'ruins', 'park', 'attraction', 'memorial'
        };
        if (trivialOsmValues.contains(trimmed)) return true;
        return trimmed.length < 15 && !trimmed.contains(' ');
      }

      if (isTrivial(shortDesc)) {
        shortDesc = null;
      }

      // AI Fallback if Wikidata/Wikipedia yield insufficient facts or trivial description
      if (facts.isEmpty || shortDesc == null || shortDesc.isEmpty) {
        debugPrint('[ResearchService] Insufficient Wiki data for ${enriched.name}, using AI fallback...');
        final aiData = await _aiService.generateBackgroundFacts(
          enriched.name, enriched.category, enriched.osmTags,
        );
        if (aiData != null) {
          final aiDesc = aiData['description'] as String?;
          if (aiDesc != null && aiDesc.trim().isNotEmpty) {
            shortDesc = aiDesc.trim();
          }
          final aiNarr = aiData['narration'] as String?;
          if (aiNarr != null && aiNarr.trim().isNotEmpty) {
            narrationText = aiNarr.trim();
          }
          final aiFacts = aiData['facts'] as List<dynamic>?;
          if (aiFacts != null && aiFacts.isNotEmpty) {
            for (final f in aiFacts) {
              final str = f.toString().trim();
              if (str.isNotEmpty) {
                facts.add(KeyFact(
                  fact: str,
                  confidence: 'high',
                ));
              }
            }
          }
          if (!sources.any((s) => s.type == 'ai')) {
            sources.add(const ResearchSource(
              url: 'https://gemini.google.com',
              title: 'ШІ-гід (Gemini)',
              type: 'ai',
            ));
          }
        }
      }

      // If narrationText is still missing, generate it with AI
      if (narrationText == null || narrationText.isEmpty) {
        final tempPoi = Poi(
          id: enriched.poiId,
          name: enriched.name,
          latitude: enriched.latitude,
          longitude: enriched.longitude,
          triggerRadius: 40,
          shortDescription: shortDesc ?? '',
          facts: facts.map((f) => f.fact).toList(),
          narrationText: '',
          sources: const [],
          osmTags: enriched.osmTags,
        );
        final genText = await _aiService.generateNarration(tempPoi);
        if (genText.isNotEmpty) {
          narrationText = genText.trim();
          if (!sources.any((s) => s.type == 'ai')) {
            sources.add(const ResearchSource(
              url: 'https://gemini.google.com',
              title: 'ШІ-розповідь (Gemini)',
              type: 'ai',
            ));
          }
        }
      }

      if ((shortDesc == null || shortDesc.isEmpty) && facts.isNotEmpty) {
        shortDesc = facts.first.fact;
      }

      // Final status determination based on gathered facts
      ResearchStatus finalStatus;
      if (facts.length >= 2 || (facts.isNotEmpty && shortDesc != null) || (narrationText != null && narrationText.isNotEmpty)) {
        finalStatus = ResearchStatus.complete;
      } else if (facts.isNotEmpty || shortDesc != null) {
        finalStatus = ResearchStatus.partial;
      } else {
        finalStatus = ResearchStatus.insufficientInformation;
      }

      final updated = enriched.copyWith(
        researchStatus: finalStatus,
        shortDescription: shortDesc,
        narrationText: narrationText,
        keyFacts: facts,
        sources: sources,
        lastResearchedAt: DateTime.now(),
      );

      await _cacheService.put(updated);
      onPoiUpdated?.call(updated);
      debugPrint('[ResearchService] Finished research for ${updated.name} -> ${updated.researchStatus.name}');
    } catch (e) {
      debugPrint('[ResearchService] Research failed for $poiId: $e');
      final failed = enriched.copyWith(
        researchStatus: ResearchStatus.failed,
        lastResearchedAt: DateTime.now(),
      );
      await _cacheService.put(failed);
      onPoiUpdated?.call(failed);
      rethrow; // Let queue handle retry
    }
  }

  /// Update narration text for a POI directly and notify listeners.
  Future<void> updateNarration(String poiId, String narration) async {
    final enriched = _cacheService.get(poiId);
    if (enriched != null) {
      final updated = enriched.copyWith(
        narrationText: narration,
        researchStatus: ResearchStatus.complete,
        lastResearchedAt: DateTime.now(),
      );
      await _cacheService.put(updated);
      onPoiUpdated?.call(updated);
    }
  }

  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }

  String _firstSentence(String text) {
    final match = RegExp(r'(?<!\b(вул|ім|р|м|с|див|напр|тис|млн|грн))\.\s+[А-ЯЄІЇA-Z]').firstMatch(text);
    if (match != null) {
      return text.substring(0, match.start + 1).trim();
    }
    final firstPeriod = text.indexOf('. ');
    if (firstPeriod > 20) {
      return text.substring(0, firstPeriod + 1).trim();
    }
    return text.length > 150 ? _truncate(text, 150) : text;
  }
}
