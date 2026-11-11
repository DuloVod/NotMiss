import '../l10n/app_lang.dart';
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
import 'text_quality.dart';
import 'source_material.dart';
import '../ui/poi_kind.dart';

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
  final OfficialSiteService _officialSite;

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
    OfficialSiteService? officialSiteService,
    this.researchDeadline = const Duration(seconds: 25),
  })  : _officialSite = officialSiteService ?? OfficialSiteService(),
        _categoryService = categoryService,
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
  ///
  /// [queueIf] limits which of them are researched right away. A search returns hundreds of
  /// places, and researching a place costs AI requests: only those the walker can reach soon
  /// should be queued (the others are queued by [queueAhead] when the walker gets closer).
  void processDiscoveredPois(List<Poi> pois, {bool Function(Poi poi)? queueIf}) {
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
      if ((queueIf == null || queueIf(poi)) && _cacheService.needsResearch(poi.id)) {
        _queue.enqueue(poi.id, enriched.priority);
      }
    }
  }

  /// Queues a place the walker is approaching, without pushing ahead of what is already queued.
  void queueAhead(String poiId) {
    final enriched = _cacheService.get(poiId);
    if (enriched != null && _cacheService.needsResearch(poiId)) {
      _queue.enqueue(poiId, enriched.priority);
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
    final usable = cached != null && !cached.isOutdated;
    final desc = (usable && cached.shortDescription?.isNotEmpty == true)
        ? cached.shortDescription
        : (poi.shortDescription.isNotEmpty ? poi.shortDescription : null);
    // Offline and before the research finishes: what the map itself says about the place
    // (description, architect, former name…) is already a verified, if short, story.
    var facts = usable ? cached.keyFacts : const <KeyFact>[];
    if (facts.isEmpty) {
      facts = [for (final line in OsmFacts.from(poi.osmTags ?? const {})) KeyFact(fact: line, confidence: 'high')];
    }
    return _buildSourceOnlyNarration(enriched, desc, facts);
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
      final offlineNarration = latest.narrationText?.isNotEmpty == true && !latest.isOutdated
          ? latest.narrationText!
          : _buildSourceOnlyNarration(latest, null, const []);
      final failed = latest.copyWith(
        contentLang: L.lang.code,
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

  /// Gathers everything real sources say about the place and builds its content from that alone.
  ///
  /// OSM tags → Wikidata (by tag, or found by name and confirmed by coordinates) → full
  /// Wikipedia articles → the place's own website. The AI only retells this material; when no
  /// source knows anything, the user is told so instead of hearing an invented story.
  Future<void> _doResearch(EnrichedPoi enriched, String poiId) async {
    try {
      final lang = L.lang; // the content is stamped with the language it was made for
      // Everything is gathered anew: earlier content may not have been verified.
      final facts = <KeyFact>[];
      final sources = <ResearchSource>[];
      final docs = <SourceDoc>[];
      String? shortDesc;
      final tags = enriched.osmTags;

      void addFact(String factText, String? sourceUrl, String confidence) {
        final trimmed = TextQuality.normalizeFact(factText.trim());
        if (trimmed.isNotEmpty &&
            TextQuality.isCleanText(trimmed) &&
            !isFallbackFact(trimmed) &&
            !facts.any((f) => _sameMeaning(f.fact, trimmed))) {
          facts.add(KeyFact(fact: trimmed, sourceUrl: sourceUrl, confidence: confidence));
        }
      }

      // STEP 1: Wikidata — by the tag, or by name if the coordinates confirm it is this place
      final taggedId = enriched.wikidataId ?? tags['wikidata'];
      final wiki = (taggedId != null && taggedId.isNotEmpty)
          ? await _wikidataService.fetchById(taggedId)
          : await _wikidataService.searchNear(enriched.name, enriched.latitude, enriched.longitude);
      if (wiki != null) {
        if (TextQuality.isCleanText(wiki.localDescription) && !isWikimediaMeta(wiki.localDescription)) {
          shortDesc = wiki.localDescription;
        }
      }

      // STEP 2: Wikipedia — articles this object links to (their identity is certain) …
      var wikiChars = 0;
      Future<void> useArticle(WikipediaArticle article) async {
        final full = await _wikipediaService.fetchFullText(article.title, lang: article.lang);
        final text = (full != null && full.length > article.extract.length) ? full : article.extract;
        docs.add(SourceDoc(type: 'wikipedia', title: L.t('Вікіпедія: ${article.title}', 'Wikipedia: ${article.title}'), url: article.url, text: text));
        sources.add(ResearchSource(url: article.url, title: 'Wikipedia (${article.title})', type: 'wikipedia'));
        wikiChars += text.length;
        if (shortDesc == null || shortDesc!.isEmpty) shortDesc = _pickDescription(article);
        _addFactsFromWikipedia(article, shortDesc, addFact);
      }

      final linked = <(String, String)>[
        if (L.en && wiki?.wikipediaEn != null) (wiki!.wikipediaEn!, 'en'),
        if (L.en && tags['wikipedia:en'] != null) (tags['wikipedia:en']!, 'en'),
        if (wiki?.wikipediaUk != null) (wiki!.wikipediaUk!, 'uk'),
        if (tags['wikipedia:uk'] != null) (tags['wikipedia:uk']!, 'uk'),
        if (tags['wikipedia'] != null) (tags['wikipedia']!, 'uk'),
        if (!L.en && wiki?.wikipediaEn != null) (wiki!.wikipediaEn!, 'en'),
        if (wiki?.wikipediaPl != null) (wiki!.wikipediaPl!, 'pl'),
        if (wiki?.wikipediaDe != null) (wiki!.wikipediaDe!, 'de'),
        if (!L.en && tags['wikipedia:en'] != null) (tags['wikipedia:en']!, 'en'),
      ];
      final seen = <String>{};
      for (final (title, lang) in linked) {
        // One thorough article is enough; other languages only add to a thin one.
        if (wikiChars >= _enoughWikipediaChars || seen.length >= 3) break;
        final article = await _wikipediaService.fetchSummary(title, lang: lang);
        if (article == null || article.extract.isEmpty || !seen.add(article.url)) continue;
        await useArticle(article);
      }

      // … otherwise search by name; a hit must prove it is about this place (see isAboutPlace)
      if (!docs.any((d) => d.type == 'wikipedia')) {
        final city = (AiService.localCity ?? AiService.placeContext?.split(',').first.trim());
        for (final lang in const ['uk', 'en']) {
          final article = await _wikipediaService.fetchSummaryOrSearch(
            enriched.name,
            lang: lang,
            lat: enriched.latitude,
            lng: enriched.longitude,
            city: city,
            kindWords: kindWordsOf(poiKindOf(_asPoi(enriched))),
          );
          if (article != null && article.extract.isNotEmpty) {
            await useArticle(article);
            break;
          }
        }
      }

      // … and if it has no article, what articles about its surroundings say about it.
      if (!docs.any((d) => d.type == 'wikipedia')) {
        final mention = await _wikipediaService.findMention(
          enriched.name,
          lat: enriched.latitude,
          lng: enriched.longitude,
          city: (AiService.localCity ?? AiService.placeContext?.split(',').first.trim()),
        );
        if (mention != null) {
          final title = L.t('Вікіпедія, стаття «${mention.articleTitle}»', 'Wikipedia, article "${mention.articleTitle}"');
          docs.add(SourceDoc(type: 'wikipedia', title: title, url: mention.url, text: mention.sentences.join('\n')));
          sources.add(ResearchSource(url: mention.url, title: title, type: 'wikipedia'));
          wikiChars += mention.sentences.join().length;
          for (final sentence in mention.sentences) {
            addFact(sentence, mention.url, 'high');
          }
        }
      }

      // Wikidata dates are sometimes about something else (the Armenian Cathedral: "1301", the
      // article: built 1363–1370). With an article at hand, a year it does not mention is dropped.
      if (wiki != null) {
        final articles = docs.where((d) => d.type == 'wikipedia').map((d) => d.text).join('\n');
        final year = RegExp(r'\d{3,4}').firstMatch(wiki.inception ?? '')?.group(0);
        final trustDate = year != null && (articles.isEmpty || articles.contains(year));
        final url = 'https://www.wikidata.org/wiki/${wiki.wikidataId}';
        final lines = <String>[
          if (TextQuality.isCleanText(wiki.localDescription) && !isWikimediaMeta(wiki.localDescription))
            wiki.localDescription!,
          if (trustDate) L.t('Створено/засновано: ${wiki.inception}', 'Built / founded: ${wiki.inception}'),
          if (wiki.architect?.isNotEmpty == true)
            L.t('Архітектор: ${wiki.architect}', 'Architect: ${wiki.architect}')
          else if (wiki.creator?.isNotEmpty == true)
            L.t('Автор/скульптор: ${wiki.creator}', 'Creator: ${wiki.creator}'),
          if (wiki.style?.isNotEmpty == true) L.t('Архітектурний стиль: ${wiki.style}', 'Architectural style: ${wiki.style}'),
          if (wiki.namedAfter?.isNotEmpty == true) L.t('Названо на честь: ${wiki.namedAfter}', 'Named after: ${wiki.namedAfter}'),
          if (wiki.commemorates?.isNotEmpty == true) L.t('Присвячено: ${wiki.commemorates}', 'Commemorates: ${wiki.commemorates}'),
          if (wiki.heritageStatus?.isNotEmpty == true) L.t('Охоронний статус: ${wiki.heritageStatus}', 'Heritage status: ${wiki.heritageStatus}'),
        ];
        if (lines.isNotEmpty) {
          docs.insert(0, SourceDoc(type: 'wikidata', title: L.t('Вікідані', 'Wikidata'), url: url, text: lines.join('\n')));
          sources.insert(0, ResearchSource(url: url, title: 'Wikidata (${wiki.label ?? wiki.wikidataId})', type: 'wikidata'));
          for (final line in lines.skip(TextQuality.isCleanText(wiki.localDescription) && !isWikimediaMeta(wiki.localDescription) ? 1 : 0)) {
            addFact(line, url, 'high');
          }
        }
      }

      // STEP 3: OpenStreetMap tags of this very object. Encyclopedias go first and take priority.
      final hasEncyclopedia = docs.isNotEmpty;
      final osmLines = OsmFacts.from(tags, withDates: !hasEncyclopedia);
      if (osmLines.isNotEmpty) {
        final url = _osmUrl(poiId);
        docs.add(SourceDoc(type: 'osm', title: 'OpenStreetMap', url: url, text: osmLines.join('\n')));
        sources.add(ResearchSource(url: url, title: 'OpenStreetMap', type: 'osm'));
        for (final line in osmLines) {
          addFact(line, url, 'high');
        }
        final description = tags['description:uk'] ?? tags['description'];
        if ((shortDesc == null || shortDesc!.isEmpty) &&
            description != null &&
            description.length >= 30 &&
            TextQuality.isCleanText(description)) {
          shortDesc = description;
        }
      }

      // STEP 4: the place's own website, when the encyclopedias say little
      final website = OsmFacts.websiteOf(tags);
      if (website != null && wikiChars < _enoughWikipediaChars ~/ 2) {
        final text = await _officialSite.fetchText(website);
        if (text != null) {
          docs.add(SourceDoc(type: 'official', title: L.t('Сайт об\'єкта', 'Official website'), url: website, text: text));
          sources.add(ResearchSource(url: website, title: L.t('Сайт об\'єкта', 'Official website'), type: 'official'));
        }
      }

      final material = SourceMaterial(docs);
      final practical = OsmFacts.practical(tags);

      // STEP 5: Content from the material
      String? narrationText;
      final keepNarration = !enriched.isOutdated &&
          enriched.researchStatus == ResearchStatus.complete &&
          !enriched.hasFallbackContent &&
          enriched.narrationText?.isNotEmpty == true;
      if (keepNarration) narrationText = TextQuality.finalizeNarration(enriched.narrationText!);

      // One or two map tags are not a story: they are read out as they are, not padded by the AI.
      if (material.promptText.length >= _minCharsForStory) {
        final primaryUrl = sources.firstWhere((s) => s.type != 'osm', orElse: () => sources.first).url;
        if (facts.length < 3 || shortDesc == null || shortDesc!.isEmpty) {
          final summary = await _aiService.summarizeSources(enriched.name, material.promptText);
          if (summary != null) {
            if (shortDesc == null || shortDesc!.isEmpty) shortDesc = summary.description;
            for (final fact in summary.facts) {
              if (facts.length >= 6) break;
              addFact(fact, primaryUrl, 'high');
            }
          }
        }
        if (narrationText == null) {
          final generated = await _aiService.generateNarration(Poi(
            id: enriched.poiId,
            name: enriched.name,
            latitude: enriched.latitude,
            longitude: enriched.longitude,
            triggerRadius: 40,
            shortDescription: '',
            facts: [material.promptText],
            narrationText: '',
            sources: const [],
            osmTags: tags,
          ));
          if (generated.isNotEmpty) {
            narrationText = generated.trim();
            sources.add(ResearchSource(url: '', title: L.t('Текст переказано ШІ за цими джерелами', 'Retold by the AI from these sources'), type: 'ai'));
          }
        }
      }

      if (shortDesc == null || isFallbackDescription(shortDesc)) {
        // A sentence from an article reads as a description; "Конфесія: …" does not.
        final sentence = facts.where((f) => !RegExp(r'^[^.]{1,30}: ').hasMatch(f.fact));
        shortDesc = sentence.isNotEmpty ? sentence.first.fact : poiKindOf(_asPoi(enriched)).label;
      }
      shortDesc = shortDesc![0].toUpperCase() + shortDesc!.substring(1);
      // AI unavailable or nothing known: the sources' own words, or an honest "not known".
      narrationText ??= _buildSourceOnlyNarration(enriched, shortDesc, facts);

      final updated = enriched.copyWith(
        researchStatus: material.isNotEmpty ? ResearchStatus.complete : ResearchStatus.insufficientInformation,
        shortDescription: shortDesc,
        narrationText: narrationText,
        keyFacts: facts,
        sources: sources,
        lastResearchedAt: DateTime.now(),
        schemaVersion: EnrichedPoi.currentSchema,
        contentLang: lang.code,
        sourceMaterial: [material.promptText, ...practical].where((e) => e.isNotEmpty).join('\n'),
      );

      await _cacheService.put(updated);
      onPoiUpdated?.call(updated);
      debugPrint('[ResearchService] Finished research for ${updated.name} -> ${updated.researchStatus.name} '
          '(${docs.map((d) => d.type).join(', ')})');
    } on TimeoutException {
      debugPrint('[ResearchService] Research timed out for $poiId');
      rethrow;
    }
  }

  /// Less material than this cannot fill a story without inventing something.
  static const int _minCharsForStory = 120;

  /// The same statement in other words ("Колишня назва: X" / "Колишня назва цього місця — X").
  static bool _sameMeaning(String a, String b) {
    final x = WikipediaService.nameStems(a);
    final y = WikipediaService.nameStems(b);
    if (x.isEmpty || y.isEmpty) return a.trim() == b.trim();
    final common = x.intersection(y).length;
    return common / (x.length < y.length ? x.length : y.length) >= 0.7;
  }

  /// "Wikimedia disambiguation page" and "list article" are not descriptions of a place: a wrong
  /// entity id (or a vague match) must not put them on the card.
  static bool isWikimediaMeta(String? text) {
    if (text == null) return false;
    final t = text.toLowerCase();
    return t.contains('wikimedia') || t.contains('вікімедіа') || t.contains('вікіпедії');
  }

  /// A longer article adds little to a 45-second story, so another language is not fetched.
  static const int _enoughWikipediaChars = 1500;

  /// "osm_way_123" → link to the object on openstreetmap.org.
  static String _osmUrl(String poiId) {
    final m = RegExp(r'^osm_(node|way|relation)_(\d+)$').firstMatch(poiId);
    return m == null ? 'https://www.openstreetmap.org' : 'https://www.openstreetmap.org/${m[1]}/${m[2]}';
  }

  static Poi _asPoi(EnrichedPoi e) => Poi(
        id: e.poiId,
        name: e.name,
        latitude: e.latitude,
        longitude: e.longitude,
        triggerRadius: 40,
        shortDescription: '',
        facts: const [],
        narrationText: '',
        sources: const [],
        osmTags: e.osmTags,
      );

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
    r'(?:^|\s)(вул|просп|пл|бул|пров|пер|ім|р|рр|м|с|див|напр|тис|млн|грн|ст|в|st|mr|mrs|ms|dr|no|vs|etc|approx)\.$',
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
      if (s.length > 300) continue; // A cut-off sentence is not a fact.
      addFact(s, article.url, 'high');
      added++;
      if (added >= 3) break;
    }
    
  }

  /// Article description when it is Ukrainian, otherwise the first sentence of the extract
  /// (if that is Ukrainian); null when only English is available.
  String? _pickDescription(WikipediaArticle a) {
    if (TextQuality.isCleanText(a.description)) return a.description;
    final first = _firstSentence(a.extract);
    return TextQuality.isCleanText(first) ? first : null;
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

  /// Spoken text assembled only from what sources say, without AI: used offline, when the AI
  /// is unavailable or when it could not write anything that passed verification.
  String _buildSourceOnlyNarration(EnrichedPoi enriched, String? shortDesc, List<KeyFact> facts) {
    final kind = poiKindOf(_asPoi(enriched));
    final name = enriched.name.replaceAll(RegExp(r'[«»"“”]'), '').trim();
    final label = kind.label.toLowerCase();
    final saysItsKind = [label, ...kindWordsOf(kind)]
        .any((w) => name.toLowerCase().contains(w.length > 5 ? w.substring(0, 5) : w));
    final intro = L.en
        ? (saysItsKind ? 'Nearby: "$name".' : 'Nearby: $label "$name".')
        : (saysItsKind ? 'Поруч — «$name».' : 'Поруч — $label «$name».');

    final parts = <String>[intro];
    final known = <String>[
      if (shortDesc != null && shortDesc.isNotEmpty && !isFallbackDescription(shortDesc) && shortDesc != kind.label)
        shortDesc,
      ...facts.map((f) => f.fact),
    ];
    for (final raw in known) {
      final line = raw.trim();
      if (line.isEmpty || line.endsWith('...') || !TextQuality.isCleanText(line)) continue;
      final sentence = RegExp(r'[.!?…]$').hasMatch(line) ? line : '$line.';
      if (parts.any((p) => _sameMeaning(p, sentence))) continue;
      if (parts.join(' ').length + sentence.length > TextQuality.maxNarrationChars) break;
      parts.add(sentence);
    }
    if (parts.length == 1) parts.add('${EnrichedPoi.noVerifiedInfoPhrase}.');
    return parts.join(' ');
  }
}
