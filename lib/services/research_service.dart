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

  /// Hard upper bound for one research run (Wikidata → Wikipedia → AI facts → AI narration).
  /// When it expires the caller proceeds with quick fallback text; the run itself keeps
  /// going in the background and updates the cache if it finishes later.
  final Duration researchDeadline;

  ResearchService({
    required PoiCategoryService categoryService,
    required PoiCacheService cacheService,
    required ResearchQueue queue,
    required WikidataService wikidataService,
    required WikipediaService wikipediaService,
    required AiService aiService,
    this.researchDeadline = const Duration(seconds: 25),
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

  bool needsResearch(String poiId) => _cacheService.needsResearch(poiId);

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

  /// Research runs currently executing, keyed by poiId. Both the background
  /// queue and [researchImmediately] go through [_processResearchTask], so a POI
  /// is never researched twice in parallel.
  final Map<String, Future<void>> _running = {};

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
    // Already running (started by the queue or another caller): join it, don't duplicate.
    final running = _running[poiId];
    if (running != null) {
      await _awaitWithDeadline(running, poiId);
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

    try {
      await _processResearchTask(poiId, force: true);
    } catch (e) {
      debugPrint('[ResearchService] researchImmediately error handled gracefully (offline fallback preserved): $e');
    }
  }

  /// Waits for [run] but never longer than [researchDeadline]; a timeout is not an error.
  Future<void> _awaitWithDeadline(Future<void> run, String poiId) async {
    try {
      await run.timeout(researchDeadline);
    } on TimeoutException {
      debugPrint('[ResearchService] Research deadline ($researchDeadline) hit for $poiId, continuing with fallback');
    } catch (_) {
      // Failure is already recorded in the cache by the run itself.
    }
  }

  /// Short spoken text that is available instantly (no network). Used when the
  /// research deadline expires or yields nothing. Never stored in the cache.
  String quickNarration(Poi poi) {
    final cached = _cacheService.get(poi.id);
    final enriched = cached ??
        EnrichedPoi(
          poiId: poi.id,
          name: poi.name,
          category: _categoryService.categorize(poi.osmTags ?? {}),
          latitude: poi.latitude,
          longitude: poi.longitude,
          researchStatus: ResearchStatus.notStarted,
        );
    final desc = (cached?.shortDescription?.isNotEmpty == true)
        ? cached!.shortDescription
        : (poi.shortDescription.isNotEmpty ? poi.shortDescription : null);
    return _buildDynamicFallbackNarration(enriched, desc);
  }

  /// Entry point for both the background queue and [researchImmediately].
  ///
  /// Joins a run that is already in flight instead of starting a duplicate, and
  /// bounds the wait by [researchDeadline] so a slow network can neither block a
  /// queue slot nor keep the user waiting at the POI. On the deadline the run keeps
  /// going in the background and updates the cache if it completes later.
  Future<void> _processResearchTask(String poiId, {bool force = false}) async {
    final existing = _running[poiId];
    if (existing != null) {
      await _awaitWithDeadline(existing, poiId);
      return;
    }

    final enriched = _cacheService.get(poiId);
    if (enriched == null) return;

    // A queued task for a POI that was meanwhile researched via researchImmediately.
    if (!force &&
        enriched.researchStatus == ResearchStatus.complete &&
        !enriched.hasFallbackContent) {
      return;
    }

    // Register synchronously (before any await) so concurrent callers always see it.
    final run = _runResearch(poiId, enriched);
    _running[poiId] = run;
    unawaited(run.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_running[poiId], run)) _running.remove(poiId);
    }));

    try {
      await run.timeout(researchDeadline);
    } on TimeoutException {
      // Not rethrown: the queue must not schedule a retry (that would start a duplicate
      // run); the original run is still alive and will populate the cache when done.
      debugPrint('[ResearchService] Research deadline ($researchDeadline) hit for $poiId');
    }
  }

  /// One research run. On any failure saves an offline-ready fallback narration so
  /// the app is never silent, then rethrows so the queue can retry.
  Future<void> _runResearch(String poiId, EnrichedPoi enriched) async {
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
      // Base the failure record on the LATEST cache entry, not the snapshot taken at
      // start, so a failed run can never overwrite a newer successful result.
      final latest = _cacheService.get(poiId) ?? enriched;
      if (latest.researchStatus == ResearchStatus.complete && !latest.hasFallbackContent) {
        return;
      }
      final offlineNarration = latest.narrationText?.isNotEmpty == true
          ? latest.narrationText!
          : _buildDynamicFallbackNarration(latest, latest.shortDescription);
      final failed = latest.copyWith(
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
      String? wikidataId = enriched.wikidataId ?? enriched.osmTags['wikidata'];

      // Purge stale dummy/fallback facts and descriptions from prior failures or initial seeds
      facts.removeWhere((f) => isFallbackFact(f.fact));
      if (isFallbackDescription(shortDesc)) {
        shortDesc = null;
      }

      void addFact(String factText, String? sourceUrl, String confidence) {
        final trimmed = factText.trim();
        if (trimmed.isNotEmpty &&
            !isFallbackFact(trimmed) &&
            !facts.any((f) => f.fact.trim() == trimmed)) {
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
          if (wikiData.inception != null && wikiData.inception!.isNotEmpty) {
            addFact('Створено/засновано: ${wikiData.inception}', 'https://www.wikidata.org/wiki/$wikidataId', 'high');
          }
          if (wikiData.architect != null && wikiData.architect!.isNotEmpty) {
            addFact('Архітектор: ${wikiData.architect}', 'https://www.wikidata.org/wiki/$wikidataId', 'high');
          } else if (wikiData.creator != null && wikiData.creator!.isNotEmpty) {
            addFact('Автор/скульптор: ${wikiData.creator}', 'https://www.wikidata.org/wiki/$wikidataId', 'high');
          }
          if (wikiData.heritageStatus != null && wikiData.heritageStatus!.isNotEmpty) {
            addFact('Охоронний статус: ${wikiData.heritageStatus}', 'https://www.wikidata.org/wiki/$wikidataId', 'high');
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
            if (wikiArticle != null && wikiArticle.extract.isNotEmpty) {
              if (shortDesc == null || shortDesc.isEmpty) {
                shortDesc = wikiArticle.description ?? _firstSentence(wikiArticle.extract);
              }
              _addFactsFromWikipedia(wikiArticle, shortDesc, addFact);
              
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
            _addFactsFromWikipedia(wikiArticle, shortDesc, addFact);
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
          _addFactsFromWikipedia(wikiArticle, shortDesc, addFact);
          sources.add(ResearchSource(
            url: wikiArticle.url,
            title: 'Wikipedia (${wikiArticle.title})',
            type: 'wikipedia',
          ));
        }
      }

      String? narrationText = enriched.narrationText;
      if (narrationText != null &&
          (narrationText.contains('Це одне з примітних місць на вашому маршруті') ||
           narrationText.contains('Зверніть увагу на його вигляд та деталі довкола') ||
           narrationText.contains('Зверніть увагу на архітектурні деталі та атмосферу довкола!'))) {
        narrationText = null;
      }

      if (isFallbackDescription(shortDesc)) {
        shortDesc = null;
      }

      // STEP 4: AI Fallback & Fact Generation
      // If we don't have enough facts (< 2) or description is missing, enrich with AI!
      if (facts.length < 2 || shortDesc == null || shortDesc.isEmpty) {
        debugPrint('[ResearchService] Insufficient Wiki data for ${enriched.name} (${facts.length} facts), using AI fallback...');
        final aiData = await _aiService.generateBackgroundFacts(
          enriched.name, enriched.category, enriched.osmTags,
        );
        if (aiData != null) {
          final aiDesc = aiData['description'] as String?;
          if (aiDesc != null && aiDesc.trim().isNotEmpty && (shortDesc == null || shortDesc.isEmpty)) {
            shortDesc = aiDesc.trim();
          }
          final aiNarr = aiData['narration'] as String?;
          if (aiNarr != null && aiNarr.trim().isNotEmpty && (narrationText == null || narrationText.isEmpty)) {
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
      if (shortDesc == null || isFallbackDescription(shortDesc)) {
        if (facts.isNotEmpty) {
          shortDesc = facts.first.fact;
        } else {
          final catLabel = PoiCategoryService.categoryLabelUk(enriched.category);
          shortDesc = '$catLabel «${enriched.name}» у Львові.';
        }
      }
      if (facts.isEmpty) {
        final catLabel = PoiCategoryService.categoryLabelUk(enriched.category);
        facts.add(KeyFact(
          fact: 'Об\'єкт належить до категорії «$catLabel» і відкритий для огляду.',
          sourceUrl: null,
          confidence: 'medium',
        ));
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
          // Dynamic graceful narration if AI generation failed/offline
          narrationText = _buildDynamicFallbackNarration(enriched, shortDesc);
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

  static bool isFallbackFact(String fact) {
    final trimmed = fact.trim();
    if (trimmed.startsWith("Об'єкт належить до категорії") ||
        trimmed.startsWith('Об’єкт належить до категорії') ||
        trimmed.contains('відкритий для огляду') ||
        trimmed.contains('відкрито для огляду') ||
        trimmed.contains('відкрито для візуального огляду') ||
        trimmed.contains('примітне місце') ||
        trimmed.contains('примітних місць')) {
      return true;
    }
    return false;
  }

  static bool isFallbackDescription(String? desc) {
    if (desc == null || desc.trim().isEmpty) return true;
    if (PoiCategoryService.isTrivialDescription(desc)) return true;
    final trimmed = desc.trim();
    if (trimmed.startsWith("Об'єкт належить до категорії") ||
        trimmed.startsWith('Об’єкт належить до категорії') ||
        trimmed.contains('примітне місце') ||
        trimmed.contains('примітних місць') ||
        trimmed.contains('відкритий для огляду')) {
      return true;
    }
    final catRegex = RegExp(
      r"^(Скульптура|Історична споруда|Парк|Фонтан|Пам’ятка|Пам'ятка|Об’єкт|Об'єкт|Цікаве місце)\s+«.+»\s+у Львові\.$",
      caseSensitive: false,
    );
    if (catRegex.hasMatch(trimmed)) {
      return true;
    }
    return false;
  }

  static final _abbrevRegex = RegExp(
    r'(?:^|\s)(вул|просп|пл|бул|пров|пер|ім|р|рр|м|с|див|напр|тис|млн|грн|ст|в)\.$',
    caseSensitive: false,
  );

  static List<String> extractSentences(String text) {
    if (text.trim().isEmpty) return [];
    final rawTokens = text.split(RegExp(r'(?<=[.!?])\s+'));
    final sentences = <String>[];
    var current = StringBuffer();

    for (final token in rawTokens) {
      if (current.isNotEmpty) {
        current.write(' ');
      }
      current.write(token.trim());

      final trimmedCurrent = current.toString();
      if (_abbrevRegex.hasMatch(trimmedCurrent)) {
        continue;
      }

      if (trimmedCurrent.endsWith('.') ||
          trimmedCurrent.endsWith('!') ||
          trimmedCurrent.endsWith('?')) {
        final candidate = trimmedCurrent.trim();
        if (candidate.length >= 25) {
          sentences.add(candidate);
        }
        current.clear();
      }
    }

    if (current.isNotEmpty) {
      final remaining = current.toString().trim();
      if (remaining.length >= 25) {
        sentences.add(remaining);
      }
    }

    return sentences;
  }

  void _addFactsFromWikipedia(
    WikipediaArticle article,
    String? shortDesc,
    void Function(String fact, String? sourceUrl, String confidence) addFact,
  ) {
    final sentences = extractSentences(article.extract);
    final shortDescNorm = shortDesc?.toLowerCase().replaceAll(RegExp(r'[^\w\sа-яєіїґ]'), '').trim() ?? '';
    
    int added = 0;
    for (final s in sentences) {
      final sNorm = s.toLowerCase().replaceAll(RegExp(r'[^\w\sа-яєіїґ]'), '').trim();
      if (shortDescNorm.isNotEmpty && (sNorm == shortDescNorm || sNorm.contains(shortDescNorm) || shortDescNorm.contains(sNorm))) {
        continue;
      }
      addFact(_truncate(s, 220), article.url, 'high');
      added++;
      if (added >= 3) break;
    }
    
    if (added == 0 && article.extract.isNotEmpty) {
      final fallbackFact = _truncate(article.extract, 180);
      if (fallbackFact != shortDesc) {
        addFact(fallbackFact, article.url, 'high');
      }
    }
  }

  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }

  String _firstSentence(String text) {
    final sentences = extractSentences(text);
    if (sentences.isNotEmpty) {
      return sentences.first;
    }
    final firstPeriod = text.indexOf('. ');
    if (firstPeriod > 20) {
      return text.substring(0, firstPeriod + 1).trim();
    }
    return text.length > 150 ? _truncate(text, 150) : text;
  }

  String _buildDynamicFallbackNarration(EnrichedPoi enriched, String? shortDesc) {
    final cat = enriched.category;
    final name = enriched.name;
    final buffer = StringBuffer();
    buffer.write('Перед вами $name');
    if (cat == PoiCategoryService.sculptureMemorial) {
      buffer.write(' — пам\'ятка скульптури та мистецтва.');
    } else if (cat == PoiCategoryService.historicalBuilding) {
      buffer.write(' — визначна історична споруда Львова.');
    } else if (cat == PoiCategoryService.naturePark) {
      buffer.write(' — мальовничий куточок міської природи.');
    } else if (cat == PoiCategoryService.fountainViewpointArchitecture) {
      buffer.write(' — виразна архітектурна прикраса міста.');
    } else {
      buffer.write(' — примітне місце на вашому маршруті.');
    }

    if (shortDesc != null &&
        shortDesc.isNotEmpty &&
        !isFallbackDescription(shortDesc)) {
      buffer.write(' $shortDesc');
    } else {
      buffer.write(' Зверніть увагу на архітектурні деталі та атмосферу довкола!');
    }
    return buffer.toString();
  }
}
