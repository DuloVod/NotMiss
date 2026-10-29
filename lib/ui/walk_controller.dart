import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../models/destination.dart';
import '../models/poi.dart';
import '../models/enriched_poi.dart';
import '../models/proximity_event.dart';
import '../models/chat_message.dart';
import '../services/location_service.dart';
import '../services/poi_engine.dart';
import '../services/content_service.dart';
import '../services/ai_service.dart';
import '../services/tts_service.dart';
import '../services/audio_player_service.dart';
import '../services/background_service.dart';
import '../services/overpass_service.dart';
import '../services/research_service.dart';
import '../services/poi_category_service.dart';
import '../services/poi_cache_service.dart';
import '../services/research_queue.dart';
import '../services/wikidata_service.dart';
import '../services/wikipedia_service.dart';
import '../services/ios_background_task.dart';

enum WalkStatus { idle, walking, stopped }

/// Central state for an active walk session.
///
/// Coordinates all services: location → POI detection → narration → TTS → audio.
/// On Android, starts a foreground service so the OS doesn't kill the app
/// when the screen turns off.
///
/// Supports two POI sources:
///   1. Static POIs from [destination] (e.g. Stryiskyi Park JSON).
///   2. Dynamic POIs loaded from Overpass API (OpenStreetMap).
/// Both are merged and deduplicated during a walk.
class WalkController extends ChangeNotifier {
  final Destination destination;
  final LocationService _locationService;
  final PoiEngine _poiEngine;
  final AiService _aiService;
  final TtsService _ttsService;
  final AudioPlayerService _audioService;
  final OverpassService _overpassService;
  final ResearchService _researchService;

  WalkStatus _status = WalkStatus.idle;
  Position? _currentPosition;
  Poi? _activePoi;
  String? _statusMessage;
  bool _isProcessing = false; // prevents concurrent POI processing
  bool _disposed = false;

  StreamSubscription<Position>? _positionSub;
  StreamSubscription? _playerStateSub;

  /// All POIs available for this walk (dynamically loaded from OSM, deduplicated).
  List<Poi> _allPois = [];

  /// Proximity events recorded during the current walk.
  final List<ProximityEvent> _proximityEvents = [];

  /// Whether OSM POIs have been loaded for this walk.
  bool _osmLoaded = false;
  
  Timer? _uiTimer;
  Timer? _osmRetryTimer;

  /// Pause before re-trying a failed POI search (public so tests can shorten it).
  Duration osmRetryDelay = const Duration(seconds: 6);

  /// TTS retry policy (public so tests can shorten it).
  int ttsAttempts = 3;
  Duration ttsRetryPause = const Duration(seconds: 3);
  Duration ttsAttemptTimeout = const Duration(seconds: 45);
  final Set<String> _preSynthesizedIds = {};

  /// Dynamic string representing current background activity
  String get backgroundActivity {
    if (_isOsmLoading) {
      return 'Пошук нових об\'єктів (OSM)...';
    }
    final active = _researchService.activeResearchCount;
    final pending = _researchService.pendingResearchCount;
    if (active > 0 || pending > 0) {
      return 'Збір історичних даних (Вікіпедія) - залишок: $pending';
    }
    return '';
  }

  WalkController({
    required this.destination,
    required String apiKey,
    LocationService? locationService,
    PoiEngine? poiEngine,
    ContentService? contentService,
    AiService? aiService,
    TtsService? ttsService,
    AudioPlayerService? audioService,
    OverpassService? overpassService,
    ResearchService? researchService,
  })  : _locationService = locationService ?? LocationService(),
        _poiEngine = poiEngine ?? PoiEngine(),
        _aiService = aiService ?? AiService(apiKey: apiKey),
        _ttsService = ttsService ?? TtsService(apiKey: apiKey),
        _audioService = audioService ?? AudioPlayerService(),
        _overpassService = overpassService ?? OverpassService(),
        _researchService = researchService ?? ResearchService(
          categoryService: PoiCategoryService(),
          cacheService: PoiCacheService(),
          queue: ResearchQueue(maxConcurrent: 2),
          wikidataService: WikidataService(),
          wikipediaService: WikipediaService(),
          aiService: aiService ?? AiService(apiKey: apiKey),
        ) {
    _researchService.onPoiUpdated = (enriched) {
      final idx = _allPois.indexWhere((p) => p.id == enriched.poiId);
      if (idx != -1) {
        final old = _allPois[idx];
        final facts = enriched.keyFacts.map((f) => f.fact).toList();
        _allPois[idx] = old.copyWith(
          shortDescription: (enriched.shortDescription?.isNotEmpty == true)
              ? enriched.shortDescription!
              : old.shortDescription,
          facts: facts.isNotEmpty ? facts : old.facts,
          narrationText: (enriched.narrationText?.isNotEmpty == true)
              ? enriched.narrationText!
              : old.narrationText,
        );
      }
      if (_activePoi?.id == enriched.poiId) {
        _activePoi = getUpdatedPoi(_activePoi!);
      }
      notifyListeners();
    };
    _researchService.init();
    _playerStateSub = _audioService.playerStateStream.listen((_) {
      notifyListeners();
    });
    _allPois = [];
  }

  WalkStatus get status => _status;
  Position? get currentPosition => _currentPosition;
  Poi? get activePoi => _activePoi;
  String? get statusMessage => _statusMessage;
  bool get isProcessing => _isProcessing;
  bool get isPlaying => _audioService.isPlaying;
  bool get isAudioPaused => _audioService.isPaused;
  bool get isAudioActive => isPlaying || isAudioPaused;
  Set<String> get triggeredPoiIds => _poiEngine.triggeredPoiIds;

  /// All POIs available for the current walk (static + OSM).
  List<Poi> get allPois => List.unmodifiable(_allPois);

  /// Number of OSM POIs loaded for this walk.
  int get osmPoiCount => _allPois.where((p) => p.confidence == 'osm').length;

  /// Whether OSM POIs have finished initial loading.
  bool get osmLoaded => _osmLoaded;

  /// Get enriched POI data from research service.
  EnrichedPoi? getEnrichedPoi(String id) => _researchService.getEnrichedData(id);

  /// Get position in research queue.
  int getQueuePosition(String id) => _researchService.getQueuePosition(id);

  /// Trigger immediate priority research for a specific POI (e.g. when user taps on it).
  /// If [force] is true, ignores cached completion status and re-runs research.
  Future<void> researchPoiNow(dynamic poiOrId, {bool force = false}) async {
    try {
      Poi? poi;
      String id;
      if (poiOrId is Poi) {
        poi = poiOrId;
        id = poi.id;
      } else {
        id = poiOrId.toString();
        for (final p in _allPois) {
          if (p.id == id) {
            poi = p;
            break;
          }
        }
      }
      await _researchService.researchImmediately(id, poi: poi, force: force);
    } catch (e) {
      debugPrint('[WalkController] researchPoiNow error: $e');
    } finally {
      notifyListeners();
    }
  }

  /// Session cache of AI chat messages per POI id.
  final Map<String, List<ChatMessage>> _chatHistoryByPoi = {};

  /// Retrieve the chat history for a POI during the current session.
  List<ChatMessage> getChatHistory(String poiId) {
    return _chatHistoryByPoi.putIfAbsent(poiId, () => []);
  }

  /// Add a chat message to the session history for a POI.
  void addChatMessage(String poiId, ChatMessage message) {
    _chatHistoryByPoi.putIfAbsent(poiId, () => []).add(message);
    notifyListeners();
  }

  /// In-memory cache of answers to specific questions per POI: [poiId][normalizedQuestion] -> answer
  final Map<String, Map<String, String>> _qaCache = {};

  /// Returns a POI populated with real-time research facts and narration.
  Poi getUpdatedPoi(Poi poi) {
    final enriched = _researchService.getEnrichedData(poi.id);
    if (enriched == null) return poi;

    final facts = enriched.keyFacts.map((f) => f.fact).toList();
    return poi.copyWith(
      shortDescription: (enriched.shortDescription?.isNotEmpty == true)
          ? enriched.shortDescription!
          : poi.shortDescription,
      facts: facts.isNotEmpty ? facts : poi.facts,
      narrationText: (enriched.narrationText?.isNotEmpty == true)
          ? enriched.narrationText!
          : poi.narrationText,
    );
  }

  int _manualPlayGen = 0;

  /// Triggers playback of the narration for a specific POI (e.g. from popup or card).
  Future<void> playNarrationForPoi(Poi poi) async {
    // If this POI is currently paused, simply resume it
    if (_audioService.isPaused && _activePoi?.id == poi.id) {
      await resumeAudio();
      return;
    }

    final gen = ++_manualPlayGen;
    _processGen++; // Invalidate any running automated POI processing
    await _audioService.stop();

    final updated = getUpdatedPoi(poi);
    _poiEngine.markTriggered(updated.id);
    _pendingPoiIds.remove(updated.id);
    _nearbyUnplayedPois.removeWhere((p) => p.id == updated.id);
    if (_currentPosition != null && !_proximityEvents.any((e) => e.poiId == updated.id)) {
      final distance = Geolocator.distanceBetween(
        _currentPosition!.latitude, _currentPosition!.longitude, updated.latitude, updated.longitude,
      );
      final event = ProximityEvent(
        poiId: updated.id,
        poiName: updated.name,
        poiLat: updated.latitude,
        poiLng: updated.longitude,
        userLat: _currentPosition!.latitude,
        userLng: _currentPosition!.longitude,
        distanceM: distance,
        timestamp: DateTime.now(),
      );
      _proximityEvents.add(event);
      onProximityEvent?.call(event);
    }
    _activePoi = updated;
    _statusMessage = '📍 ${updated.name} — підготовка розповіді…';
    _isProcessing = true;
    notifyListeners();

    var failed = false;
    await IosBackgroundTask.begin();
    try {
      var currentPoi = updated;
      String narration = currentPoi.narrationText;
      final enriched = _researchService.getEnrichedData(currentPoi.id);
      final hasFallback = enriched?.hasFallbackContent ?? false;
      if (narration.isEmpty || hasFallback) {
        // Run or await research immediately — guarantees Wikipedia/Wikidata is consulted first
        await _researchService.researchImmediately(currentPoi.id, poi: currentPoi, force: hasFallback);
        if (gen != _manualPlayGen) return;
        currentPoi = getUpdatedPoi(currentPoi);
        narration = currentPoi.narrationText;
        _activePoi = currentPoi;
      }

      if (narration.isEmpty) {
        try {
          narration = await _aiService
              .generateNarration(currentPoi)
              .timeout(const Duration(seconds: 15));
        } on TimeoutException {
          narration = '';
        }
        if (narration.isNotEmpty) {
          await _researchService.updateNarration(currentPoi.id, narration, poi: currentPoi);
          currentPoi = getUpdatedPoi(currentPoi);
          _activePoi = currentPoi;
        }
        if (gen != _manualPlayGen) return;
      }

      // Hard safety net — TTS must never be called with empty text
      if (narration.isEmpty) {
        narration = _researchService.quickNarration(currentPoi);
      }

      if (narration.isNotEmpty) {
        currentPoi = currentPoi.copyWith(narrationText: narration);
        _activePoi = currentPoi;
        _statusMessage = '🔊 ${currentPoi.name} — озвучення…';
        notifyListeners();
        final audioPath = await _synthesizeWithRetry(narration, currentPoi.id, () => gen != _manualPlayGen);
        if (gen != _manualPlayGen || audioPath == null) return;

        _statusMessage = '🎧 ${currentPoi.name}';
        notifyListeners();
        await _audioService.play(audioPath);
        if (gen != _manualPlayGen) return;
      }
    } catch (e) {
      debugPrint('[WalkController] Play narration error: $e');
      if (gen == _manualPlayGen) {
        failed = true;
        _statusMessage = '📍 ${updated.name} — озвучення недоступне, розповідь текстом';
        notifyListeners();
      }
    } finally {
      await IosBackgroundTask.end();
      if (gen == _manualPlayGen && _activePoi?.id == updated.id) {
        _isProcessing = false;
        // Keep the card (and its text) after a failure so the user can read / retry.
        if (!failed) {
          if (_status == WalkStatus.walking) {
            _statusMessage = 'Прогулянка — слухаю (${_proximityEvents.length} зафіксовано)';
          } else {
            _statusMessage = null;
          }
          _activePoi = null;
        }
        notifyListeners();
      }
    }
  }

  /// Pause current audio playback.
  Future<void> pauseAudio() async {
    await _audioService.pause();
    if (_activePoi != null) {
      _statusMessage = '⏸️ ${_activePoi!.name} — пауза';
    }
    notifyListeners();
  }

  /// Resume current audio playback.
  Future<void> resumeAudio() async {
    await _audioService.resume();
    if (_activePoi != null) {
      _statusMessage = '🎧 ${_activePoi!.name}';
    }
    notifyListeners();
  }

  /// Stop current audio playback and cancel in-flight narration generation.
  Future<void> stopAudio() async {
    _processGen++;
    _manualPlayGen++;
    await _audioService.stop();
    _activePoi = null;
    _isProcessing = false;
    if (_status == WalkStatus.walking) {
      _statusMessage = 'Прогулянка — слухаю (${_proximityEvents.length} зафіксовано)';
    } else {
      _statusMessage = null;
    }
    notifyListeners();
  }

  /// Ask Gemini a question about a POI, using in-memory cache for repeated questions during the session.
  Future<String> askAiAboutPoi(Poi poi, String question) async {
    final normalized = question.trim().toLowerCase();
    final poiQa = _qaCache.putIfAbsent(poi.id, () => {});
    if (poiQa.containsKey(normalized) && poiQa[normalized]!.isNotEmpty) {
      debugPrint('[WalkController] Returning cached session AI answer for "$question" on ${poi.name}');
      return poiQa[normalized]!;
    }

    final updated = getUpdatedPoi(poi);
    final answer = await _aiService.answerQuestionAboutPoi(updated, question);
    if (answer.isNotEmpty) {
      poiQa[normalized] = answer;
    }
    return answer;
  }

  /// Synthesize and play speech for a text response.
  Future<void> speakText(String text) async {
    try {
      final audioPath = await _ttsService.synthesize(text, 'chat_${DateTime.now().millisecondsSinceEpoch}');
      await _audioService.play(audioPath);
    } catch (e) {
      debugPrint('[WalkController] speakText error: $e');
    }
  }

  /// Proximity events recorded during this walk.
  List<ProximityEvent> get proximityEvents =>
      List.unmodifiable(_proximityEvents);

  /// Callback that external code can set to react to proximity events.
  /// Does NOT trigger AI or audio — just a hook for future use.
  void Function(ProximityEvent event)? onProximityEvent;

  Future<void> startWalk() async {
    if (_status == WalkStatus.walking) return;
    final granted = await _locationService.requestPermission();
    if (!granted) {
      _statusMessage = 'Для роботи аудіогіда потрібен доступ до геолокації.';
      notifyListeners();
      return;
    }

    // Set the audio category while the app is still in the foreground.
    unawaited(_audioService.prepareSession());

    _poiEngine.resetSession();
    _pendingPoiIds.clear();
    _proximityEvents.clear();
    _osmLoaded = false;
    _status = WalkStatus.walking;
    _activePoi = null;

    _allPois = [];
    _statusMessage = 'Завантаження точок інтересу…';
    notifyListeners();

    // Start Android foreground service (keeps GPS alive when screen is off)
    await BackgroundService.start();

    _locationService.start();

    // Try to get initial position and load OSM POIs
    _loadOsmPoisAsync();

    _positionSub?.cancel();
    _positionSub = _locationService.positionStream.listen(_onPosition);

    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_status == WalkStatus.walking && backgroundActivity.isNotEmpty) {
        notifyListeners();
      }
    });
  }

  bool _isOsmLoading = false;

  /// Force a clean refresh of OSM POIs from Overpass, bypassing cache.
  Future<void> reloadOsmPois() async {
    await _overpassService.clearCache();
    _osmLoaded = false;
    await _loadOsmPoisAsync(force: true);
  }

  /// Load OSM POIs in the background, without blocking the walk start.
  Future<void> _loadOsmPoisAsync({bool force = false}) async {
    if (_isOsmLoading) return;
    _isOsmLoading = true;
    try {
      // Wait for first GPS fix (max 15 seconds)
      Position? pos = _locationService.lastPosition ??
          await _locationService.lastKnownPosition();
      // A fresh fix may have arrived while we waited for the OS-cached one.
      pos ??= _locationService.lastPosition;
      if (pos == null) {
        pos = await _locationService.positionStream
            .first
            .timeout(const Duration(seconds: 15));
      }

      final osmPois =
          await _overpassService.loadPois(pos.latitude, pos.longitude, force: force);

      // An empty list caused by network trouble is a failure, not "no points here":
      // the catch below keeps the walk in "not loaded" state and schedules a retry.
      if (osmPois.isEmpty && _overpassService.lastLoadFailed) {
        throw StateError('Overpass unavailable');
      }

      // Перевіряємо статус одразу після await — між await та мутацією
      // міг виконатися stopWalk(), тому перевіряємо тут, а не раніше.
      if (_status != WalkStatus.walking) return;

      // Merge: add OSM POIs that don't duplicate existing ones
      final existingIds = _allPois.map((p) => p.id).toSet();
      final newPois = osmPois.where((p) => !existingIds.contains(p.id)).toList();

      final deduped = <Poi>[];
      for (final osmPoi in newPois) {
        // Prevent duplicate entries for the exact same object from OSM (identical name within 15m)
        final isExactDuplicate = deduped.any((d) =>
            d.name.trim().toLowerCase() == osmPoi.name.trim().toLowerCase() &&
            Geolocator.distanceBetween(d.latitude, d.longitude, osmPoi.latitude, osmPoi.longitude) < 15);
        if (!isExactDuplicate) {
          deduped.add(osmPoi);
        }
      }

      _allPois.addAll(deduped);
      _osmLoaded = true;

      // Queue only the NEW POIs for background research (Wikidata, Wikipedia)
      _researchService.processDiscoveredPois(deduped);

      if (_status == WalkStatus.walking) {
        _statusMessage =
            'Прогулянка — ${_allPois.length} точок (${deduped.length} з OSM)';
        notifyListeners();
      }

      debugPrint('[WalkController] Loaded POIs: ${_allPois.length} total (${deduped.length} new from OSM)');
    } catch (e) {
      debugPrint('[WalkController] OSM load failed: $e');
      _osmLoaded = false;
      if (_status == WalkStatus.walking) {
        _statusMessage = e is TimeoutException
            ? 'Очікую GPS-сигнал… (вийдіть на відкрите місце)'
            : 'Немає зв\'язку з картою — повторюю пошук точок…';
        notifyListeners();
        // Retry on its own: do not depend on the user moving to trigger another attempt.
        _osmRetryTimer?.cancel();
        _osmRetryTimer = Timer(osmRetryDelay, () {
          if (!_disposed && _status == WalkStatus.walking && !_osmLoaded && !_isOsmLoading) {
            _loadOsmPoisAsync();
          }
        });
      }
    } finally {
      _isOsmLoading = false;
    }
  }

  void stopWalk() {
    _processGen++;
    _manualPlayGen++;
    _uiTimer?.cancel();
    _uiTimer = null;
    _osmRetryTimer?.cancel();
    _positionSub?.cancel();
    _positionSub = null;
    _locationService.stop();
    _audioService.stop();
    _status = WalkStatus.stopped;
    _isProcessing = false;
    _activePoi = null;
    _pendingPoiIds.clear();
    _statusMessage =
        'Прогулянка завершена. ${_poiEngine.triggeredPoiIds.length} місць відвідано.';
    notifyListeners();

    // Stop the foreground service
    BackgroundService.stop();
  }

  /// Pre-synthesizes audio for an approaching POI in the background,
  /// so that when the user enters the trigger zone with the screen locked,
  /// audio starts playing immediately with zero network latency.
  void _preSynthesizePoi(Poi poi) {
    if (_preSynthesizedIds.contains(poi.id)) return;
    final updated = getUpdatedPoi(poi);
    final narration = updated.narrationText;
    if (narration.isNotEmpty) {
      _preSynthesizedIds.add(poi.id);
      _ttsService.synthesize(narration, poi.id).catchError((e) {
        _preSynthesizedIds.remove(poi.id);
        debugPrint('[WalkController] Pre-synthesis failed for ${poi.name}: $e');
        return '';
      });
    }
  }

  int _processGen = 0;

  /// Points the user entered while another narration was busy.
  final Set<String> _pendingPoiIds = {};
  List<Poi> _nearbyUnplayedPois = [];
  List<Poi> get nearbyUnplayedPois => List.unmodifiable(_nearbyUnplayedPois);

  Future<void> _onPosition(Position pos) async {
    _currentPosition = pos;

    // Dynamically reload OSM POIs if user has moved significantly or if initial load timed out
    if (!_isOsmLoading && (!_osmLoaded || _overpassService.shouldReload(pos.latitude, pos.longitude))) {
      debugPrint('[WalkController] Loading/reloading OSM POIs...');
      _loadOsmPoisAsync();
    }
    // Завчасно піднімаємо пріоритет для точок, до яких наближається користувач (150 метрів)
    Poi? closestApproachingPoi;
    double closestApproachingDist = double.infinity;

    for (final p in _allPois) {
      if (!_poiEngine.triggeredPoiIds.contains(p.id)) {
        final dist = Geolocator.distanceBetween(
          pos.latitude, pos.longitude,
          p.latitude, p.longitude,
        );
        if (dist < 150) {
          _researchService.prioritizePoi(p.id);
        }
        // Знаходимо одну найближчу точку на наближенні (до 100м)
        if (dist <= 100 && dist > p.triggerRadius && dist < closestApproachingDist) {
          closestApproachingDist = dist;
          closestApproachingPoi = p;
        }
      }
    }

    // Заздалегідь синтезуємо аудіо лише для однієї найближчої точки, уникаючи спаму черги TTS
    if (closestApproachingPoi != null && !_isProcessing) {
      _preSynthesizePoi(closestApproachingPoi);
    }

    // Знаходимо всі точки поруч, які ще не були відвідані
    final triggerable = _poiEngine.findAllTriggerablePois(
      _allPois,
      pos.latitude,
      pos.longitude,
    );

    // Виключаємо активну точку
    if (_activePoi != null) {
      triggerable.removeWhere((p) => p.id == _activePoi!.id);
    }

    _dismissStaleCard(pos);

    // Points entered while another narration was busy must not be lost when the user
    // walks on: remember them and still play them within a wider "just passed" radius.
    if (_isProcessing) {
      for (final p in triggerable) {
        _pendingPoiIds.add(p.id);
      }
    }
    final ready = List<Poi>.of(triggerable);
    if (!_isProcessing && _pendingPoiIds.isNotEmpty) {
      for (final p in _allPois) {
        if (!_pendingPoiIds.contains(p.id) ||
            _poiEngine.triggeredPoiIds.contains(p.id) ||
            ready.any((r) => r.id == p.id)) {
          continue;
        }
        final d = Geolocator.distanceBetween(pos.latitude, pos.longitude, p.latitude, p.longitude);
        if (d <= math.max(p.triggerRadius * 2.5, 100.0)) ready.add(p);
      }
      ready.sort((a, b) =>
          Geolocator.distanceBetween(pos.latitude, pos.longitude, a.latitude, a.longitude).compareTo(
              Geolocator.distanceBetween(pos.latitude, pos.longitude, b.latitude, b.longitude)));
      if (_activePoi != null) ready.removeWhere((p) => p.id == _activePoi!.id);
    }
    _nearbyUnplayedPois = ready;
    notifyListeners();

    // Якщо нічого не грає і є точки - запускаємо найближчу
    if (!_isProcessing && ready.isNotEmpty) {
      _processPoi(ready.first, pos);
    }
  }

  void switchToPoi(Poi poi) {
    if (_status != WalkStatus.walking) return;
    _audioService.stop(); // Зупиняємо поточне аудіо
    if (_currentPosition != null) {
      _processPoi(poi, _currentPosition!);
    }
  }

  Future<void> _processPoi(Poi poi, Position pos) async {
    final gen = ++_processGen;

    _poiEngine.markTriggered(poi.id);
    _pendingPoiIds.remove(poi.id);
    _isProcessing = true;

    // Merge enriched research data if available
    final activePoi = getUpdatedPoi(poi);

    _activePoi = activePoi;
    _nearbyUnplayedPois.removeWhere((p) => p.id == activePoi.id);

    final distance = Geolocator.distanceBetween(
      pos.latitude, pos.longitude, activePoi.latitude, activePoi.longitude,
    );
    final event = ProximityEvent(
      poiId: activePoi.id,
      poiName: activePoi.name,
      poiLat: activePoi.latitude,
      poiLng: activePoi.longitude,
      userLat: pos.latitude,
      userLng: pos.longitude,
      distanceM: distance,
      timestamp: DateTime.now(),
    );
    _proximityEvents.add(event);
    debugPrint('[WalkController] Proximity event: $event');

    onProximityEvent?.call(event);

    _statusMessage = '📍 ${activePoi.name} — генерація розповіді…';
    notifyListeners();

    BackgroundService.updateNotification(
      'NotMiss — ${activePoi.name}',
      'Generating audio narration…',
    );

    var currentPoi = activePoi;
    var failed = false;
    await IosBackgroundTask.begin();
    try {
      String narration = currentPoi.narrationText;
      final enriched = _researchService.getEnrichedData(currentPoi.id);
      // Re-research fallback content only after the cache cooldown, otherwise an offline
      // user would wait for the deadline at every single point.
      final refresh = (enriched?.hasFallbackContent ?? false) &&
          _researchService.needsResearch(currentPoi.id);
      if (narration.isEmpty || refresh) {
        // Joins research already started by the queue (or runs it) — bounded by the
        // research deadline, so a slow network can't keep the user waiting for minutes.
        await _researchService.researchImmediately(currentPoi.id, poi: currentPoi, force: refresh);
        if (gen != _processGen) return; // Cancelled while waiting
        currentPoi = getUpdatedPoi(currentPoi);
        narration = currentPoi.narrationText;
      }

      // Instant offline text: the guide is never silent and the card never empty.
      if (narration.isEmpty) {
        narration = _researchService.quickNarration(currentPoi);
      }

      // Show the text in the card right away, before (possibly slow) synthesis.
      currentPoi = currentPoi.copyWith(narrationText: narration);
      _activePoi = currentPoi;
      _statusMessage = '🔊 ${currentPoi.name} — озвучення…';
      notifyListeners();

      final audioPath = await _synthesizeWithRetry(narration, currentPoi.id, () => gen != _processGen);
      if (gen != _processGen || audioPath == null) return; // Відмінено

      _statusMessage = '🎧 ${currentPoi.name}';
      notifyListeners();

      BackgroundService.updateNotification(
        'NotMiss — ${currentPoi.name}',
        'Now playing audio narration 🎧',
      );

      await _audioService.play(audioPath);
      if (gen != _processGen) return; // Відмінено

      BackgroundService.updateNotification(
        'NotMiss — Walk in progress',
        'Voice guide is active. You\'ll be notified near each point.',
      );
    } catch (e) {
      if (gen == _processGen) {
        // The POI stays marked as triggered (unmarking would retry forever when offline),
        // but the card with the narration text stays on screen so nothing is lost.
        failed = true;
        debugPrint('[WalkController] Error processing POI ${currentPoi.name}: $e');
        _statusMessage = '📍 ${currentPoi.name} — озвучення недоступне, розповідь текстом';
        notifyListeners();
        BackgroundService.updateNotification(
          'NotMiss',
          'Narration available for ${currentPoi.name}.',
        );
      }
    } finally {
      await IosBackgroundTask.end();
      if (gen == _processGen) {
        _isProcessing = false;
        // _activePoi is intentionally kept: the card with the text stays until the user
        // walks away (see _dismissStaleCard), starts another POI or closes it.
        if (_status == WalkStatus.walking && !failed) {
          _statusMessage = 'Прогулянка — слухаю (${_proximityEvents.length} зафіксовано)';
        }
        notifyListeners();

        // Natural 2-second pause before checking for the next triggerable POI
        Future.delayed(const Duration(seconds: 2), () {
          if (!_disposed && _currentPosition != null && _status == WalkStatus.walking && !_isProcessing) {
            _onPosition(_currentPosition!);
          }
        });
      }
    }
  }

  /// TTS with a bounded number of attempts and a pause between them.
  /// Returns null if cancelled meanwhile; rethrows the last error when attempts run out.
  Future<String?> _synthesizeWithRetry(
    String text,
    String poiId,
    bool Function() isCancelled,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= ttsAttempts; attempt++) {
      try {
        return await _ttsService.synthesize(text, poiId).timeout(ttsAttemptTimeout);
      } catch (e) {
        lastError = e;
        debugPrint('[WalkController] TTS attempt $attempt/$ttsAttempts failed: $e');
        if (attempt < ttsAttempts) {
          _statusMessage = '🔊 повторна спроба озвучення ($attempt/$ttsAttempts)…';
          notifyListeners();
          await Future.delayed(ttsRetryPause);
          if (isCancelled()) return null;
        }
      }
    }
    throw lastError!;
  }

  /// Clears a finished card once the user has walked well away from its POI.
  void _dismissStaleCard(Position pos) {
    final active = _activePoi;
    if (active == null || _isProcessing || isAudioActive) return;
    final dist = Geolocator.distanceBetween(
      pos.latitude, pos.longitude, active.latitude, active.longitude,
    );
    if (dist > math.max(active.triggerRadius * 3, 80.0)) {
      _activePoi = null;
      if (_status == WalkStatus.walking) {
        _statusMessage = 'Прогулянка — слухаю (${_proximityEvents.length} зафіксовано)';
      }
    }
  }

  @visibleForTesting
  Future<void> debugProcessPoi(Poi poi, Position pos) => _processPoi(poi, pos);

  @visibleForTesting
  Future<void> debugOnPosition(Position pos) => _onPosition(pos);

  @visibleForTesting
  void debugSetPois(List<Poi> pois) {
    _allPois = List.of(pois);
    _osmLoaded = true;
    _status = WalkStatus.walking;
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _uiTimer?.cancel();
    _osmRetryTimer?.cancel();
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _locationService.dispose();
    _audioService.dispose();
    _researchService.dispose();
    BackgroundService.stop();
    super.dispose();
  }
}
