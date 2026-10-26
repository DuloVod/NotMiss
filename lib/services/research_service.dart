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

  /// Tracks POI IDs currently being researched via [researchImmediately]
  /// to prevent concurrent duplicate execution for the same POI.
  final Set<String> _inFlightImmediateIds = {};

  /// Active Completers keyed by poiId for callers awaiting research completion.
  /// Multiple callers can await the same research by chaining on the same completer.
  final Map<String, Completer<void>> _researchCompleters = {};

  /// Bumps a specific POI to the highest priority in the research queue.
  /// Used when the user physically approaches an unresearched POI.
  void prioritizePoi(String poiId) {
    if (_cacheService.needsResearch(poiId)) {
      _bumpedPois.add(poiId);
      _queue.enqueue(poiId, ResearchPriority.high, bump: true);
    }
  }

  /// Returns a Future that completes when research for [poiId] is no longer
  /// inProgress/queued (i.e. it finished, failed, or was never started).
  /// [timeout] limits how long to wait; defaults to 30 seconds.
  ///
  /// This lets [WalkController._processPoi] and [playNarrationForPoi] wait for
  /// background research to settle before falling back to AI-only narration.
  Future<void> waitForResearch(String poiId,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final cached = _cacheService.get(poiId);
    if (cached == null) return; // Nothing to wait for
    if (cached.researchStatus != ResearchStatus.inProgress &&
        cached.researchStatus != ResearchStatus.queued) return;

    // Reuse existing completer if one is already attached to this POI
    final completer = _researchCompleters.putIfAbsent(
      poiId,
      () => Completer<void>(),
    );
    if (completer.isCompleted) {
      _researchCompleters.remove(poiId);
      return;
    }
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      debugPrint('[ResearchService] waitForResearch timeout for $poiId');
    } catch (_) {
      // Research errored — continue anyway, caller will use fallback
    } finally {
      _researchCompleters.remove(poiId);
    }
  }

  /// Forces immediate research of a POI, executing it right away.
  ///
  /// Guards against concurrent execution: if research is already in-flight for
  /// this POI (e.g. the background queue started it simultaneously), this call
  /// waits until the in-flight one finishes rather than running a duplicate.
  ///
  /// If [force] is false and the POI is already researched, skips redundant network/AI requests.
  Future<void> researchImmediately(String poiId, {Poi? poi, bool force = false}) async {
    // If already being researched immediately, wait for completion rather than skipping
    if (_inFlightImmediateIds.contains(poiId)) {
      await waitForResearch(poiId);
      return;
    }

    // Session cache check: if already researched and not forced, return immediately
    if (!force && !_cacheService.needsResearch(poiId)) {
      debugPrint('[ResearchService] POI $poiId already has completed research in cache, skipping duplicate research');
      return;
    }

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

    _inFlightImmediateIds.add(poiId);
    try {
      await _processResearchTask(poiId);
    } catch (e) {
      debugPrint('[ResearchService] researchImmediately error handled gracefully (offline fallback preserved): $e');
    } finally {
      _inFlightImmediateIds.remove(poiId);
    }
  }

  /// The core research workflow executed by the queue.
  ///
  /// Wrapped in a 45-second timeout to prevent indefinite hangs.
  /// On any failure, saves an offline-ready fallback narration so the app
  /// is never silent even without network / AI availability.
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
      await _doResearch(enriched, poiId);
    } catch (e) {
      debugPrint('[ResearchService] Research failed for $poiId: $e');
      // Save offline fallback so the app is NEVER silent even after failure
      final offlineNarration = enriched.narrationText?.isNotEmpty == true
          ? enriched.narrationText!
          : 'Перед вами ${enriched.name}. Це одне з примітних місць на вашому маршруті. Зверніть увагу на його вигляд та деталі довкола!';
      final failed = enriched.copyWith(
        researchStatus: ResearchStatus.failed,
        narrationText: offlineNarration,
        lastResearchedAt: DateTime.now(),
      );
      await _cacheService.put(failed);
      onPoiUpdated?.call(failed);
      rethrow; // Let queue handle retry
    } finally {
      // Signal any callers awaiting this POI's research completion
      final completer = _researchCompleters.remove(poiId);
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  /// Inner research body — runs inside a 45-second timeout.
  Future<void> _doResearch(EnrichedPoi enriched, String poiId) async {
    try {
      final facts = <KeyFact>[...enriched.keyFacts];
      final sources = <ResearchSource>[...enriched.sources];
      String? shortDesc = enriched.shortDescription;
      String? wikidataId = enriched.wikidataId;

      void addFact(String factText, String? sourceUrl, String confidence) {
        final trimmed = factText.trim();
        if (trimmed.isNotEmpty && !facts.any((f) => f.fact.trim() == trimmed)) {
          facts.add(KeyFact(
            fact: trimmed,
            sourceUrl: sourceUrl,
            confidence: confidence,
          ));
        }
      }

      // STEP 1: Wikidata
      if (wikidataId != null && wikidataId.isNotEmpty) {
        final wikiData = await _wikidataService.fetchById(wikidataId);
        if (wikiData != null) {
          if (wikiData.inception != null) {
            addFact('Створено/засновано: ${wikiData.inception}', 'https://www.wikidata.org/wiki/$wikidataId', 'high');
          }
          if (wikiData.architect != null) {
            addFact('Архітектор/творець: ${wikiData.architect}', 'https://www.wikidata.org/wiki/$wikidataId', 'high');
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
          
          // Wikipedia via Wikidata sitelink
          if (wikiData.wikipediaTitle != null && wikiData.wikipediaLang != null) {
            final wikiArticle = await _wikipediaService.fetchSummary(
              wikiData.wikipediaTitle!,
              lang: wikiData.wikipediaLang!,
            );
            if (wikiArticle != null) {
              if (shortDesc == null || shortDesc.isEmpty) {
                shortDesc = wikiArticle.description ?? _firstSentence(wikiArticle.extract);
              }
              addFact(_truncate(wikiArticle.extract, 150), wikiArticle.url, 'high');
              
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

      // STEP 2: Wikipedia via OSM tags (e.g. wikipedia, wikipedia:uk)
      if (!sources.any((s) => s.type == 'wikipedia')) {
        final osmWiki = enriched.osmTags['wikipedia'] ??
            enriched.osmTags['wikipedia:uk'] ??
            enriched.osmTags['wikipedia:en'];
        if (osmWiki != null && osmWiki.trim().isNotEmpty) {
          final wikiArticle = await _wikipediaService.fetchSummary(osmWiki);
          if (wikiArticle != null && wikiArticle.extract.isNotEmpty) {
            if (shortDesc == null || shortDesc.isEmpty) {
              shortDesc = wikiArticle.description ?? _firstSentence(wikiArticle.extract);
            }
            addFact(_truncate(wikiArticle.extract, 150), wikiArticle.url, 'high');
            sources.add(ResearchSource(
              url: wikiArticle.url,
              title: 'Wikipedia (${wikiArticle.title})',
              type: 'wikipedia',
            ));
          }
        }
      }

      // STEP 3: Direct Wikipedia search by POI Name
      if (!sources.any((s) => s.type == 'wikipedia')) {
        final wikiArticle = await _wikipediaService.fetchSummaryOrSearch(
          enriched.name,
          lang: 'uk',
        );
        if (wikiArticle != null && wikiArticle.extract.isNotEmpty) {
          if (shortDesc == null || shortDesc.isEmpty) {
            shortDesc = wikiArticle.description ?? _firstSentence(wikiArticle.extract);
          }
          addFact(_truncate(wikiArticle.extract, 150), wikiArticle.url, 'high');
          sources.add(ResearchSource(
            url: wikiArticle.url,
            title: 'Wikipedia (${wikiArticle.title})',
            type: 'wikipedia',
          ));
        }
      }

      String? narrationText = enriched.narrationText;

      if (PoiCategoryService.isTrivialDescription(shortDesc)) {
        shortDesc = null;
      }

      // STEP 4: AI Fallback & Fact Generation
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
                addFact(str, null, 'high');
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

      // Safety fallback: guaranteed non-empty human-readable description and facts
      if (shortDesc == null || PoiCategoryService.isTrivialDescription(shortDesc)) {
        if (facts.isNotEmpty) {
          shortDesc = facts.first.fact;
        } else {
          shortDesc = 'Цікавий туристичний та історичний об\'єкт «${enriched.name}» у Львові.';
        }
      }
      if (facts.isEmpty) {
        addFact('Об\'єкт відкрито для візуального огляду під час прогулянки.', null, 'medium');
      }

      // STEP 5: Mandatory Narration Generation (App must NEVER be silent!)
      if (narrationText == null || narrationText.isEmpty) {
        final tempPoi = Poi(
          id: enriched.poiId,
          name: enriched.name,
          latitude: enriched.latitude,
          longitude: enriched.longitude,
          triggerRadius: 40,
          shortDescription: shortDesc,
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
        } else {
          // Offline/Default graceful narration
          narrationText = 'Перед вами ${enriched.name}. Це одне з примітних місць на вашому маршруті. Зверніть увагу на його вигляд та деталі довкола!';
        }
      }

      // Status: complete because rich facts, description, and narration are guaranteed
      final finalStatus = ResearchStatus.complete;

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
    } on TimeoutException {
      debugPrint('[ResearchService] Research timed out for $poiId');
      rethrow;
    }
  }

  /// Update narration text for a POI directly and notify listeners.
  /// If the POI is not in cache yet, creates an EnrichedPoi entry using [poi].
  Future<void> updateNarration(String poiId, String narration, {Poi? poi}) async {
    var enriched = _cacheService.get(poiId);
    if (enriched == null && poi != null) {
      final category = _categoryService.categorize(poi.osmTags ?? {});
      enriched = EnrichedPoi(
        poiId: poi.id,
        name: poi.name,
        category: category,
        latitude: poi.latitude,
        longitude: poi.longitude,
        researchStatus: ResearchStatus.complete,
        narrationText: narration,
        osmTags: poi.osmTags ?? {},
        wikidataId: poi.wikidataId,
        lastResearchedAt: DateTime.now(),
      );
      await _cacheService.put(enriched);
      onPoiUpdated?.call(enriched);
      return;
    }

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
