import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../models/destination.dart';
import '../models/poi.dart';
import '../models/enriched_poi.dart';
import '../models/proximity_event.dart';
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
  final ContentService _contentService;
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

  /// All POIs available for this walk (static + dynamic, deduplicated).
  List<Poi> _allPois = [];

  /// Proximity events recorded during the current walk.
  final List<ProximityEvent> _proximityEvents = [];

  /// Whether OSM POIs have been loaded for this walk.
  bool _osmLoaded = false;
  
  Timer? _uiTimer;

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
        _contentService = contentService ?? ContentService(),
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
      notifyListeners();
    };
    _researchService.init();
    _playerStateSub = _audioService.playerStateStream.listen((_) {
      notifyListeners();
    });
  }

  WalkStatus get status => _status;
  Position? get currentPosition => _currentPosition;
  Poi? get activePoi => _activePoi;
  String? get statusMessage => _statusMessage;
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
  Future<void> researchPoiNow(dynamic poiOrId) async {
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
    await _researchService.researchImmediately(id, poi: poi);
    notifyListeners();
  }

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

    try {
      String narration = updated.narrationText;
      if (narration.isEmpty) {
        narration = await _aiService.generateNarration(updated);
        if (narration.isNotEmpty) {
          await _researchService.updateNarration(updated.id, narration);
        }
        if (gen != _manualPlayGen) return;
      }

      if (narration.isNotEmpty) {
        _statusMessage = '🔊 ${updated.name} — озвучення…';
        notifyListeners();
        final audioPath = await _ttsService.synthesize(narration, updated.id);
        if (gen != _manualPlayGen) return;

        _statusMessage = '🎧 ${updated.name}';
        notifyListeners();
        await _audioService.play(audioPath);
        if (gen != _manualPlayGen) return;
      }
    } catch (e) {
      debugPrint('[WalkController] Play narration error: $e');
    } finally {
      if (gen == _manualPlayGen && _activePoi?.id == updated.id) {
        _isProcessing = false;
        _activePoi = null;
        if (_status == WalkStatus.walking) {
          _statusMessage = 'Прогулянка — слухаю (${_proximityEvents.length} зафіксовано)';
        } else {
          _statusMessage = null;
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

  /// Ask Gemini a question about a POI.
  Future<String> askAiAboutPoi(Poi poi, String question) async {
    final updated = getUpdatedPoi(poi);
    return await _aiService.answerQuestionAboutPoi(updated, question);
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
      _statusMessage = 'Location permission required to start a walk.';
      notifyListeners();
      return;
    }

    _poiEngine.resetSession();
    _proximityEvents.clear();
    _osmLoaded = false;
    _status = WalkStatus.walking;
    _activePoi = null;

    // Start with static POIs from destination
    _allPois = List<Poi>.from(destination.pois);
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
      if (_status == WalkStatus.walking) notifyListeners();
    });
  }

  bool _isOsmLoading = false;

  /// Load OSM POIs in the background, without blocking the walk start.
  Future<void> _loadOsmPoisAsync() async {
    if (_isOsmLoading) return;
    _isOsmLoading = true;
    try {
      // Wait for first GPS fix (max 15 seconds)
      Position? pos = _locationService.lastPosition;
      if (pos == null) {
        pos = await _locationService.positionStream
            .first
            .timeout(const Duration(seconds: 15));
      }

      final osmPois =
          await _overpassService.loadPois(pos.latitude, pos.longitude);

      // Перевіряємо статус одразу після await — між await та мутацією
      // міг виконатися stopWalk(), тому перевіряємо тут, а не раніше.
      if (_status != WalkStatus.walking) return;

      // Merge: add OSM POIs that don't duplicate static ones
      final existingIds = _allPois.map((p) => p.id).toSet();
      final newPois = osmPois.where((p) => !existingIds.contains(p.id)).toList();

      // Also deduplicate by proximity (within 30m of an existing static POI)
      final deduped = <Poi>[];
      for (final osmPoi in newPois) {
        final tooClose = _allPois.any((existing) {
          final dist = Geolocator.distanceBetween(
            existing.latitude, existing.longitude,
            osmPoi.latitude, osmPoi.longitude,
          );
          return dist < 30;
        });
        if (!tooClose) deduped.add(osmPoi);
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

      debugPrint('[WalkController] Merged POIs: ${_allPois.length} total '
          '(${destination.pois.length} static + ${deduped.length} OSM)');
    } catch (e) {
      debugPrint('[WalkController] OSM load failed: $e');
      _osmLoaded = false;
      if (_status == WalkStatus.walking) {
        _statusMessage = 'Прогулянка — ${_allPois.length} точок (пошук OSM...)';
        notifyListeners();
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
    _positionSub?.cancel();
    _positionSub = null;
    _locationService.stop();
    _audioService.stop();
    _status = WalkStatus.stopped;
    _isProcessing = false;
    _statusMessage =
        'Прогулянка завершена. ${_poiEngine.triggeredPoiIds.length} місць відвідано.';
    notifyListeners();

    // Stop the foreground service
    BackgroundService.stop();
  }

  int _processGen = 0;
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
    for (final p in _allPois) {
      if (!_poiEngine.triggeredPoiIds.contains(p.id)) {
        final dist = Geolocator.distanceBetween(
          pos.latitude, pos.longitude,
          p.latitude, p.longitude,
        );
        if (dist < 150) {
          _researchService.prioritizePoi(p.id);
        }
      }
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

    _nearbyUnplayedPois = triggerable;
    notifyListeners();

    // Якщо нічого не грає і є точки - запускаємо найближчу
    if (!_isProcessing && triggerable.isNotEmpty) {
      _processPoi(triggerable.first, pos);
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

    try {
      String narration = activePoi.narrationText;
      if (narration.isEmpty) {
        final aiText = await _aiService.generateNarration(activePoi);
        if (gen != _processGen) return; // Відмінено
        narration = _contentService.getNarration(activePoi, aiText: aiText);
      }

      if (narration.isNotEmpty) {
        _statusMessage = '🔊 ${activePoi.name} — озвучення…';
        notifyListeners();

        final audioPath = await _ttsService.synthesize(narration, activePoi.id);
        if (gen != _processGen) return; // Відмінено

        _statusMessage = '🎧 ${activePoi.name}';
        notifyListeners();

        BackgroundService.updateNotification(
          'NotMiss — ${activePoi.name}',
          'Now playing audio narration 🎧',
        );

        await _audioService.play(audioPath);
        if (gen != _processGen) return; // Відмінено
      } else {
        // Для OSM або точок без розповіді
        _statusMessage = '📍 ${activePoi.name} — зафіксовано';
        notifyListeners();
      }

      BackgroundService.updateNotification(
        'NotMiss — Walk in progress',
        'Voice guide is active. You\'ll be notified near each point.',
      );
    } catch (e) {
      if (gen == _processGen) {
        _poiEngine.unmarkTriggered(poi.id); // Allow retry later if transient error occurred
        _statusMessage = '⚠️ Помилка озвучення ${activePoi.name}: $e';
        notifyListeners();
        BackgroundService.updateNotification(
          'NotMiss',
          'Could not generate narration for ${activePoi.name}.',
        );
      }
    } finally {
      if (gen == _processGen) {
        _isProcessing = false;
        _activePoi = null;
        if (_status == WalkStatus.walking) {
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

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _uiTimer?.cancel();
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _locationService.dispose();
    _audioService.dispose();
    _researchService.dispose();
    BackgroundService.stop();
    super.dispose();
  }
}
