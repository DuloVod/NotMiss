import 'dart:async';
import 'dart:ui' show Rect;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:geolocator/geolocator.dart';
import '../l10n/app_lang.dart';
import '../l10n/place_name.dart';
import '../models/destination.dart';
import '../services/settings_store.dart';
import '../services/report_service.dart';
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
import '../services/text_quality.dart';
import '../services/chat_guard.dart';
import '../services/now_playing_service.dart';
import '../services/visited_store.dart';
import '../services/live_activity_service.dart';
import '../services/place_context_service.dart';
import 'guide_status.dart';
import 'poi_kind.dart';

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
  final NowPlayingService _nowPlaying;
  final VisitedStore _visitedStore;
  final LiveActivityService _liveActivity;
  final SettingsStore _settings;
  final ReportService _reports;
  final PlaceContextService _placeService;

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

  /// Vibration + soft chime before an automatically triggered narration.
  bool playArrivalCue = true;

  /// TTS retry policy (public so tests can shorten it).
  int ttsAttempts = 3;
  Duration ttsRetryPause = const Duration(seconds: 3);
  Duration ttsAttemptTimeout = const Duration(seconds: 45);
  final Set<String> _preSynthesizedIds = {};

  /// Dynamic string representing current background activity
  String get backgroundActivity {
    if (_isOsmLoading) {
      return L.t('Пошук нових об\'єктів (OSM)...', 'Looking for new places (OSM)...');
    }
    final active = _researchService.activeResearchCount;
    final pending = _researchService.pendingResearchCount;
    if (active > 0 || pending > 0) {
      return L.t('Збір історичних даних (Вікіпедія) - залишок: $pending', 'Gathering history (Wikipedia) - left: $pending');
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
    NowPlayingService? nowPlaying,
    VisitedStore? visitedStore,
    PlaceContextService? placeService,
    LiveActivityService? liveActivity,
    SettingsStore? settingsStore,
    ReportService? reportService,
  })  : _settings = settingsStore ?? SettingsStore(),
        _reports = reportService ?? ReportService(),
        _liveActivity = liveActivity ?? LiveActivityService(),
        _placeService = placeService ?? PlaceContextService(),
         _nowPlaying = nowPlaying ?? NowPlayingService(),
        _visitedStore = visitedStore ?? VisitedStore(),
        _locationService = locationService ?? LocationService(),
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
        _allPois[idx] = _mergeEnriched(_allPois[idx], enriched);
      }
      if (_activePoi?.id == enriched.poiId) {
        _activePoi = getUpdatedPoi(_activePoi!);
      }
      notifyListeners();
    };
    _researchService.init();
    _playerStateSub = _audioService.playerStateStream.listen((_) {
      _syncNowPlaying();
      _refreshLiveActivity();
      notifyListeners();
    });
    _nowPlaying.onPlay = () => unawaited(resumeAudio());
    _nowPlaying.onPause = () => unawaited(pauseAudio());
    _nowPlaying.onReplay = () => unawaited(replayAudio());
    _nowPlaying.onSkip = () => unawaited(skipNarration());
    _nowPlaying.onToggle = () => unawaited(isPlaying ? pauseAudio() : resumeAudio());
    unawaited(_visitedStore.init().then((_) => notifyListeners()));
    _allPois = [];
  }

  AppLang get lang => L.lang;

  /// Places the user has reported as inaccurate.
  Set<String> get reportedPoiIds => _settings.reported;

  /// Opens the share sheet with a ready message about [poi] (what the app said, where it came
  /// from, why it is wrong). Returns false when the sheet could not be opened.
  Future<bool> reportPlace(Poi poi, ReportReason reason, {String comment = '', Rect? origin}) async {
    final text = ReportService.compose(
      poi: getUpdatedPoi(poi),
      enriched: _researchService.getEnrichedData(poi.id),
      reason: reason,
      comment: comment,
      lang: L.lang,
    );
    try {
      await _reports.send(text, origin: origin);
    } catch (e) {
      debugPrint('[WalkController] report failed: $e');
      return false;
    }
    await _settings.markReported(poi.id);
    notifyListeners();
    return true;
  }

  /// Switches the language of the interface, the stories, the AI and the voice. Places researched
  /// in the other language are researched again when the walker gets close.
  Future<void> setLang(AppLang lang) async {
    if (lang == L.lang) return;
    L.lang = lang;
    await _settings.setLang(lang);
    AiService.placeContext = null; // "Львів, Україна" → "Lviv, Ukraine"
    AiService.localCity = null;
    _contextPos = null;
    final pos = _currentPosition;
    if (pos != null) unawaited(_refreshPlaceContext(pos));
    if (_status == WalkStatus.walking && pos != null) {
      _researchService.processDiscoveredPois(_allPois, queueIf: (p) =>
          Geolocator.distanceBetween(pos.latitude, pos.longitude, p.latitude, p.longitude) <= researchAheadM);
    }
    _lastLive = null;
    _refreshLiveActivity(force: true);
    notifyListeners();
  }

  WalkStatus get status => _status;
  Position? get currentPosition => _currentPosition;
  Poi? get activePoi => _activePoi;
  String? get statusMessage => _statusMessage;
  bool get isProcessing => _isProcessing;
  bool get isPlaying => _audioService.isPlaying;
  bool get isAudioPaused => _audioService.isPaused;
  bool get isAudioActive => isPlaying || isAudioPaused;

  /// The story itself (not the chime before it) is loaded: position and duration are meaningful.
  bool get isNarrationLoaded => _audioService.isNarrationLoaded;
  Stream<Duration> get audioPositionStream => _audioService.positionStream;
  Duration get audioPosition => _audioService.position;
  Duration? get audioDuration => _audioService.duration;
  Set<String> get triggeredPoiIds => _poiEngine.triggeredPoiIds;

  /// Places that no verified source knows anything about: shown on the map with a "not narrated"
  /// mark, never narrated (an animal enclosure, a tank, a sign without a story).
  Set<String> get silentPoiIds => {
        for (final p in _allPois)
          if (isSilentPoi(p.id)) p.id,
      };

  bool isSilentPoi(String id) => _researchService.getEnrichedData(id)?.isSilent ?? false;

  /// Places the user has physically passed (this walk + earlier walks, persisted).
  Set<String> get passedPoiIds => {
        ..._visitedStore.places.where((p) => p.passed).map((p) => p.id),
        ..._poiEngine.triggeredPoiIds,
      };

  /// Places whose narration the user has heard to the end.
  Set<String> get listenedPoiIds =>
      _visitedStore.places.where((p) => p.listened).map((p) => p.id).toSet();

  /// Passed or listened — anything the guide has already dealt with.
  Set<String> get visitedPoiIds => {..._visitedStore.ids, ..._poiEngine.triggeredPoiIds};

  /// How many different places the user has dealt with in total.
  int get totalVisitedCount => _visitedStore.count;

  /// Everything the user has dealt with, newest first.
  List<VisitedPlace> get visitedPlaces => _visitedStore.places;

  /// Narration heard to the end.
  List<VisitedPlace> get listenedPlaces => _visitedStore.listenedPlaces;

  /// Walked past, narration not heard.
  List<VisitedPlace> get passedOnlyPlaces => _visitedStore.passedOnlyPlaces;

  void _markPassed(Poi poi) {
    unawaited(_visitedStore
        .markPassed(poi.id, name: poi.name, kind: poiKindOf(poi).name)
        .then((isNew) => isNew ? notifyListeners() : null));
  }

  void _markListened(Poi poi) {
    unawaited(_visitedStore
        .markListened(poi.id, name: poi.name, kind: poiKindOf(poi).name)
        .then((_) => notifyListeners()));
  }

  /// The closest place the user has not dealt with yet, with the distance in metres.
  ({Poi poi, double meters})? nearestUnvisited({String? excluding, double maxMeters = 1500}) {
    final pos = _currentPosition;
    if (pos == null) return null;
    final visited = visitedPoiIds;
    Poi? best;
    var bestD = maxMeters;
    for (final p in _allPois) {
      if (p.id == excluding || visited.contains(p.id)) continue;
      final d = Geolocator.distanceBetween(pos.latitude, pos.longitude, p.latitude, p.longitude);
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    return best == null ? null : (poi: best, meters: bestD);
  }

  /// Whether "next" would start another narration (otherwise it simply stops this one).
  bool get hasNextNarration => _nearbyUnplayedPois.isNotEmpty || _pendingPoiIds.isNotEmpty;

  bool _appInBackground = false;

  /// Whether the app is in the background / the screen is locked.
  bool get appInBackground => _appInBackground;

  /// Called by the UI on every app lifecycle change. Going to the background refreshes the
  /// lock-screen card.
  void setAppLifecycle(AppLifecycleState state) {
    final background = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (background == _appInBackground) return;
    _appInBackground = background;
    if (background) _syncNowPlaying();
  }

  /// Publishes the lock-screen card for [poi] right away (before audio actually starts).
  void _publishNowPlaying(Poi poi, {required bool playing}) {
    _audioRequested = playing;
    _refreshLiveActivity();
    unawaited(_nowPlaying.update(
      title: poi.shownName,
      subtitle: _lockScreenSubtitle(poi),
      playing: playing,
      elapsed: _audioService.position,
      duration: _audioService.duration,
    ));
  }

  /// "85 м" / "1,2 км" — rounded so that the always-on indicator does not flicker.
  static String formatDistance(double meters) => L.distance(meters);

  /// What the always-on indicator (Live Activity) should say right now; null when no walk.
  GuideLiveState? get liveState {
    if (_status != WalkStatus.walking) return null;
    final poi = _activePoi;
    if (poi != null && (isAudioActive || _audioRequested)) {
      final next = nearestUnvisited(excluding: poi.id, maxMeters: 400);
      return GuideLiveState(
        title: poi.shownName,
        subtitle: next != null
            ? L.t('Далі: ${next.poi.shownName} · ${formatDistance(next.meters)}', 'Next: ${next.poi.shownName} · ${formatDistance(next.meters)}')
            : L.t('Гід розповідає', 'The guide is telling'),
        badge: next != null ? formatDistance(next.meters) : '',
        speaking: true,
        paused: isAudioPaused,
        controls: true,
        canSkipNext: hasNextNarration,
      );
    }
    if (_isProcessing && poi != null) {
      return GuideLiveState(title: poi.shownName, subtitle: L.t('Готуємо розповідь…', 'Preparing the story…'), speaking: true);
    }
    final near = nearestUnvisited();
    if (near != null) {
      return GuideLiveState(
        title: near.poi.shownName,
        subtitle: L.t('Найближче місце · ${poiKindOf(near.poi).label}', 'Nearest place · ${poiKindOf(near.poi).label}'),
        badge: formatDistance(near.meters),
      );
    }
    return GuideLiveState(
      title: L.t('Гід працює', 'Guide is on'),
      subtitle: _osmLoaded
          ? L.t('Поруч немає нових місць', 'No new places nearby')
          : L.t('Шукаємо місця поруч…', 'Looking for places nearby…'),
    );
  }

  /// True from the moment playback is requested until the narration ends or is cut.
  bool _audioRequested = false;

  GuideLiveState? _lastLive;
  DateTime _lastLiveAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Pushes the indicator when it changed (and at most every few seconds).
  void _refreshLiveActivity({bool force = false}) {
    final state = liveState;
    if (state == null) return;
    final now = DateTime.now();
    if (!force) {
      final last = _lastLive;
      if (state == last) return;
      // A changed meaning (other place, narration started / ended) goes out at once; mere
      // distance changes ("85 м" → "80 м") are limited to one update every few seconds.
      String shape(String t) => t.replaceAll(RegExp(r'[\d,]+'), '#');
      final onlyDistance = last != null &&
          state.title == last.title &&
          state.speaking == last.speaking &&
          state.paused == last.paused &&
          state.controls == last.controls &&
          state.canSkipNext == last.canSkipNext &&
          shape(state.subtitle) == shape(last.subtitle) &&
          shape(state.badge) == shape(last.badge);
      if (onlyDistance && now.difference(_lastLiveAt) < const Duration(seconds: 4)) return;
    }
    _lastLive = state;
    _lastLiveAt = now;
    unawaited(_liveActivity.show(state));
  }

  /// "Далі: <nearest place not yet visited> · 85 м" for the lock-screen card; falls back to the
  /// kind of the current place when nothing is close.
  String _lockScreenSubtitle(Poi current) {
    final next = nearestUnvisited(excluding: current.id, maxMeters: 400);
    if (next != null) return L.t('Далі: ${next.poi.shownName} · ${formatDistance(next.meters)}', 'Next: ${next.poi.shownName} · ${formatDistance(next.meters)}');
    return poiKindOf(current).label;
  }

  DateTime _lastLockScreenRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// Updates the lock-screen card (title, play/pause state, progress).
  void _syncNowPlaying() {
    final poi = _activePoi;
    if (poi != null && isAudioActive) {
      _lastLockScreenRefresh = DateTime.now();
      unawaited(_nowPlaying.update(
        title: poi.shownName,
        subtitle: _lockScreenSubtitle(poi),
        playing: isPlaying,
        elapsed: _audioService.position,
        duration: _audioService.duration,
      ));
    } else if (!_isProcessing) {
      unawaited(_nowPlaying.clear());
    }
  }

  // ── Calm status (one indicator instead of a log of steps) ────────────────────
  bool _permissionDenied = false;
  bool _narrationFailed = false;
  bool _waitingForGps = false;
  int _osmFailures = 0;

  /// After this many failed place searches in a row the user is told (and can retry).
  static const int osmFailuresBeforeNotice = 3;

  /// What to tell the user right now, or null when there is nothing worth saying.
  /// Self-healing situations show a quiet "busy" line; only things the user can act
  /// on come with a button.
  GuideStatus? get guideStatus {
    if (_status == WalkStatus.idle) {
      return _permissionDenied
          ? GuideStatus(L.t('Потрібен доступ до геолокації', 'Location access is needed'), GuideTone.attention,
              actionLabel: L.t('Дозволити', 'Allow'))
          : null;
    }
    if (_status == WalkStatus.stopped) return null;

    if (_narrationFailed && _activePoi != null && !_isProcessing) {
      return GuideStatus(L.t('Не вдалося озвучити — розповідь текстом', 'Could not play the voice — story as text'),
          GuideTone.attention,
          actionLabel: L.t('Повторити', 'Retry'));
    }
    if (isAudioActive) return null;
    if (_isProcessing) return GuideStatus(L.t('Готуємо розповідь…', 'Preparing the story…'), GuideTone.busy);
    if (!_osmLoaded) {
      if (_waitingForGps) {
        return GuideStatus(L.t('Шукаємо GPS-сигнал…', 'Looking for a GPS signal…'), GuideTone.busy);
      }
      if (_osmFailures >= osmFailuresBeforeNotice) {
        return GuideStatus(L.t('Немає зв\'язку — місця не завантажились', 'No connection — places did not load'),
            GuideTone.attention,
            actionLabel: L.t('Повторити', 'Retry'));
      }
      return GuideStatus(L.t('Шукаємо місця поруч…', 'Looking for places nearby…'), GuideTone.busy);
    }
    return null;
  }

  /// The button next to [guideStatus].
  Future<void> runStatusAction() async {
    if (_status == WalkStatus.idle && _permissionDenied) {
      await startWalk();
    } else if (_narrationFailed && _activePoi != null) {
      await replayAudio();
    } else if (!_osmLoaded) {
      _osmFailures = 0;
      notifyListeners();
      await reloadOsmPois();
    }
  }

  /// All POIs available for the current walk (static + OSM).
  List<Poi> get allPois => List.unmodifiable(_allPois);

  /// Number of OSM POIs loaded for this walk.
  int get osmPoiCount => _allPois.where((p) => p.confidence == 'osm').length;

  /// Whether OSM POIs have finished initial loading.
  bool get osmLoaded => _osmLoaded;

  /// Get enriched POI data from research service.
  EnrichedPoi? getEnrichedPoi(String id) {
    final enriched = _researchService.getEnrichedData(id);
    // Written by an older version, not verified against sources: never shown.
    return enriched == null || enriched.isOutdated ? null : enriched;
  }

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
    return _mergeEnriched(poi, enriched);
  }

  /// Applies research results to a POI, but never surfaces broken content that may sit in
  /// the cache from earlier versions: leaked prompt text, cut-off or non-Ukrainian narration,
  /// English / placeholder descriptions and facts.
  Poi _mergeEnriched(Poi poi, EnrichedPoi enriched) {
    if (enriched.isOutdated) return poi;
    final facts = enriched.keyFacts
        .map((f) => TextQuality.normalizeFact(f.fact))
        .where((f) => TextQuality.isCleanText(f) && !ResearchService.isFallbackFact(f))
        .toList();
    final desc = enriched.shortDescription;
    final narr = enriched.narrationText;
    return poi.copyWith(
      shortDescription: (desc != null &&
              desc.isNotEmpty &&
              TextQuality.isCleanText(desc) &&
              !ResearchService.isFallbackDescription(desc))
          ? desc
          : poi.shortDescription,
      facts: facts.isNotEmpty ? facts : poi.facts,
      narrationText: (narr != null && narr.isNotEmpty && !TextQuality.isBadStoredNarration(narr))
          ? TextQuality.finalizeNarration(narr)
          : poi.narrationText,
    );
  }

  int _manualPlayGen = 0;

  /// Triggers playback of the narration for a specific POI (e.g. from popup or card).
  Future<void> playNarrationForPoi(Poi poi, {bool restart = false}) async {
    // If this POI is currently paused, simply resume it
    if (!restart && _audioService.isPaused && _activePoi?.id == poi.id) {
      await resumeAudio();
      return;
    }

    final gen = ++_manualPlayGen;
    _processGen++; // Invalidate any running automated POI processing
    await _audioService.stop();

    var updated = getUpdatedPoi(poi);
    if (updated.narrationText.isEmpty && poi.narrationText.isNotEmpty) {
      updated = updated.copyWith(narrationText: poi.narrationText);
    }
    _narrationFailed = false;
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
    _statusMessage = L.t('📍 ${updated.shownName} — підготовка розповіді…', '📍 ${updated.shownName} — preparing the story…');
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

      if (EnrichedPoi.hasNoVerifiedInfo(narration) || isSilentPoi(currentPoi.id)) {
        _activePoi = currentPoi.copyWith(narrationText: narration);
        _statusMessage = L.t('📍 ${currentPoi.shownName} — не озвучується: немає перевірених джерел',
            '📍 ${currentPoi.shownName} — not narrated: no verified sources');
        notifyListeners();
        return;
      }

      if (narration.isNotEmpty) {
        currentPoi = currentPoi.copyWith(narrationText: narration);
        _activePoi = currentPoi;
        _statusMessage = L.t('🔊 ${currentPoi.shownName} — озвучення…', '🔊 ${currentPoi.shownName} — generating the voice…');
        notifyListeners();
        final audioPath = await _synthesizeWithRetry(narration, currentPoi.id, () => gen != _manualPlayGen);
        if (gen != _manualPlayGen || audioPath == null) return;

        _statusMessage = '🎧 ${currentPoi.shownName}';
        notifyListeners();
        _publishNowPlaying(currentPoi, playing: true);
        await _playWithRetry(audioPath, () => gen != _manualPlayGen);
        if (gen != _manualPlayGen) return;
        _markListened(currentPoi);
      }
    } catch (e) {
      debugPrint('[WalkController] Play narration error: $e');
      if (gen == _manualPlayGen) {
        failed = true;
        _narrationFailed = true;
        _statusMessage = L.t('📍 ${updated.shownName} — озвучення недоступне, розповідь текстом', '📍 ${updated.shownName} — voice unavailable, story as text');
        notifyListeners();
      }
    } finally {
      await IosBackgroundTask.end();
      if (gen == _manualPlayGen) _audioRequested = false;
      if (gen == _manualPlayGen && _activePoi?.id == updated.id) {
        _isProcessing = false;
        // Keep the card (and its text) after a failure so the user can read / retry.
        if (!failed) {
          if (_status == WalkStatus.walking) {
            _statusMessage = L.t('Прогулянка — слухаю (${_proximityEvents.length} зафіксовано)', 'Walk — listening (${_proximityEvents.length} recorded)');
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
    _refreshLiveActivity();
    if (_activePoi != null) {
      _statusMessage = L.t('⏸️ ${_activePoi!.shownName} — пауза', '⏸️ ${_activePoi!.shownName} — paused');
    }
    notifyListeners();
  }

  /// Resume current audio playback.
  Future<void> resumeAudio() async {
    await _audioService.resume();
    _refreshLiveActivity();
    if (_activePoi != null) {
      _statusMessage = '🎧 ${_activePoi!.shownName}';
    }
    notifyListeners();
  }

  /// Play the current narration again from the beginning.
  Future<void> replayAudio() async {
    final poi = _activePoi;
    if (poi == null) return;
    await playNarrationForPoi(poi, restart: true);
  }

  /// Drop the current narration and move on: the next waiting place (if any) starts at once.
  Future<void> skipNarration() async {
    await stopAudio();
    final pos = _currentPosition;
    if (pos != null && _status == WalkStatus.walking) {
      await _onPosition(pos);
    }
  }

  /// Stop current audio playback and cancel in-flight narration generation.
  Future<void> stopAudio() async {
    _processGen++;
    _manualPlayGen++;
    await _audioService.stop();
    _audioRequested = false;
    _activePoi = null;
    _narrationFailed = false;
    _isProcessing = false;
    if (_status == WalkStatus.walking) {
      _statusMessage = L.t('Прогулянка — слухаю (${_proximityEvents.length} зафіксовано)', 'Walk — listening (${_proximityEvents.length} recorded)');
    } else {
      _statusMessage = null;
    }
    notifyListeners();
  }

  /// A place's chat is for curiosity about it, not free access to the model.
  static const int maxQuestionsPerPlace = 30;
  final Map<String, int> _chatQuestions = {};

  /// Ask Gemini a question about a POI, using in-memory cache for repeated questions during the session.
  Future<String> askAiAboutPoi(Poi poi, String question) async {
    // Rejected questions cost nothing: no research, no model request, no place in the limit.
    final local = ChatGuard.localAnswer(question, poi.name);
    if (local != null) return local;

    final normalized = question.trim().toLowerCase();
    final poiQa = _qaCache.putIfAbsent(poi.id, () => {});
    if (poiQa.containsKey(normalized) && poiQa[normalized]!.isNotEmpty) {
      debugPrint('[WalkController] Returning cached session AI answer for "$question" on ${poi.name}');
      return poiQa[normalized]!;
    }

    final asked = _chatQuestions[poi.id] ?? 0;
    if (asked >= maxQuestionsPerPlace) return ChatGuard.limitReached;
    _chatQuestions[poi.id] = asked + 1;

    // The answer comes from the place's sources, so they must be collected first.
    if (_researchService.needsResearch(poi.id)) {
      await _researchService.researchImmediately(poi.id, poi: poi);
    }
    var updated = getUpdatedPoi(poi);
    final material = getEnrichedPoi(poi.id)?.sourceMaterial;
    if (material != null && material.isNotEmpty) {
      updated = updated.copyWith(facts: [...updated.facts, material]);
    }
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
    _permissionDenied = !granted;
    if (!granted) {
      _statusMessage = L.t('Для роботи аудіогіда потрібен доступ до геолокації.', 'The audio guide needs location access.');
      notifyListeners();
      return;
    }

    // Set the audio category while the app is still in the foreground.
    unawaited(_audioService.prepareSession());

    _poiEngine.resetSession();
    _pendingPoiIds.clear();
    _proximityEvents.clear();
    _narrationFailed = false;
    _waitingForGps = false;
    _osmFailures = 0;
    _osmLoaded = false;
    _status = WalkStatus.walking;
    _activePoi = null;

    _allPois = [];
    _statusMessage = L.t('Завантаження точок інтересу…', 'Loading points of interest…');
    notifyListeners();

    // Always-on indicator (lock screen / Dynamic Island) — must be started in the foreground.
    _lastLive = null;
    _refreshLiveActivity(force: true);

    // Start Android foreground service (keeps GPS alive when screen is off)
    await BackgroundService.start();

    _locationService.start();

    // Try to get initial position and load OSM POIs
    _loadOsmPoisAsync();

    _positionSub?.cancel();
    _positionSub = _locationService.positionStream.listen(_onPosition);

    _uiTimer?.cancel();
    var ticks = 0;
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Heartbeat: the indicator turns "stale" if it is not refreshed for two minutes.
      if (_status == WalkStatus.walking && ++ticks % 45 == 0) _refreshLiveActivity(force: true);
      if (_status == WalkStatus.walking && backgroundActivity.isNotEmpty) {
        notifyListeners();
      }
    });
  }

  bool _isOsmLoading = false;

  /// Places closer than this get researched in advance, so the story is ready on arrival.
  static const double researchAheadM = 350;

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
      _osmFailures = 0;
      _waitingForGps = false;

      // Queue only the NEW POIs for background research (Wikidata, Wikipedia)
      // Research checks articles against the city, so it must be known first (bounded by the
      // lookup's own timeout; on failure the checks just stay stricter).
      final fix = pos;
      await _refreshPlaceContext(fix);
      if (_status != WalkStatus.walking) return;

      // Only what the walker can reach soon: a search returns hundreds of places, and the rest
      // is queued on approach (see _onPosition).
      _researchService.processDiscoveredPois(deduped, queueIf: (p) =>
          Geolocator.distanceBetween(fix.latitude, fix.longitude, p.latitude, p.longitude) <= researchAheadM);

      if (_status == WalkStatus.walking) {
        _statusMessage =
            L.t('Прогулянка — ${_allPois.length} точок (${deduped.length} з OSM)', 'Walk — ${_allPois.length} places (${deduped.length} from OSM)');
        notifyListeners();
      }

      debugPrint('[WalkController] Loaded POIs: ${_allPois.length} total (${deduped.length} new from OSM)');
    } catch (e) {
      debugPrint('[WalkController] OSM load failed: $e');
      _osmLoaded = false;
      _waitingForGps = e is TimeoutException;
      if (e is! TimeoutException) _osmFailures++;
      if (_status == WalkStatus.walking) {
        _statusMessage = e is TimeoutException
            ? L.t('Очікую GPS-сигнал… (вийдіть на відкрите місце)', 'Waiting for GPS… (step out into the open)')
            : L.t('Немає зв\'язку з картою — повторюю пошук точок…', 'No connection to the map — retrying the search…');
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
    _narrationFailed = false;
    unawaited(_nowPlaying.clear());
    _lastLive = null;
    unawaited(_liveActivity.end());
    _pendingPoiIds.clear();
    _statusMessage =
        L.t('Прогулянка завершена. ${_poiEngine.triggeredPoiIds.length} місць відвідано.', 'Walk finished. ${_poiEngine.triggeredPoiIds.length} places visited.');
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

  Position? _contextPos;
  bool _contextLoading = false;

  /// Learns the city around the user (once, and again after moving far) for the AI prompts.
  Future<void> _refreshPlaceContext(Position pos) async {
    if (_contextLoading) return;
    final last = _contextPos;
    if (last != null &&
        Geolocator.distanceBetween(last.latitude, last.longitude, pos.latitude, pos.longitude) <
            PlaceContextService.reuseRadiusM) {
      return;
    }
    _contextLoading = true;
    try {
      final ctx = await _placeService.lookup(pos.latitude, pos.longitude);
      if (ctx != null) {
        AiService.placeContext = ctx;
        _contextPos = pos;
        AiService.localCity = L.uk
            ? ctx.split(',').first.trim()
            : await _placeService.lookupLocalCity(pos.latitude, pos.longitude);
      }
    } finally {
      _contextLoading = false;
    }
  }

  Future<void> _onPosition(Position pos) async {
    _currentPosition = pos;
    unawaited(_refreshPlaceContext(pos));
    _refreshLiveActivity();
    // The lock-screen card shows the nearest next place: keep it fresh while narrating.
    if (isAudioActive &&
        DateTime.now().difference(_lastLockScreenRefresh) > const Duration(seconds: 5)) {
      _syncNowPlaying();
    }

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
        } else if (dist < researchAheadM) {
          _researchService.queueAhead(p.id);
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

    // Walking through a place's radius counts as "passed", whether or not it gets narrated.
    for (final p in triggerable) {
      _markPassed(p);
    }

    // Виключаємо активну точку
    if (_activePoi != null) {
      triggerable.removeWhere((p) => p.id == _activePoi!.id);
    }

    _dropAbandonedPause(pos);
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
    _markPassed(poi);
    _pendingPoiIds.remove(poi.id);
    _isProcessing = true;
    _narrationFailed = false;

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

    _statusMessage = L.t('📍 ${activePoi.shownName} — генерація розповіді…', '📍 ${activePoi.shownName} — preparing the story…');
    notifyListeners();

    BackgroundService.updateNotification(
      'NotMiss — ${activePoi.shownName}',
      'Generating audio narration…',
    );

    var currentPoi = activePoi;
    var failed = false;
    var keepStatus = false; // the "not narrated" note stays until the next place
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

      // Nothing verified is known about the place: it stays on the map, but is not narrated.
      if (EnrichedPoi.hasNoVerifiedInfo(narration) || isSilentPoi(currentPoi.id)) {
        _activePoi = currentPoi.copyWith(narrationText: narration);
        _statusMessage = L.t('📍 ${currentPoi.shownName} — не озвучується: немає перевірених джерел',
            '📍 ${currentPoi.shownName} — not narrated: no verified sources');
        keepStatus = true;
        notifyListeners();
        return;
      }

      // Show the text in the card right away, before (possibly slow) synthesis.
      currentPoi = currentPoi.copyWith(narrationText: narration);
      _activePoi = currentPoi;
      _statusMessage = L.t('🔊 ${currentPoi.shownName} — озвучення…', '🔊 ${currentPoi.shownName} — generating the voice…');
      notifyListeners();

      final audioPath = await _synthesizeWithRetry(narration, currentPoi.id, () => gen != _processGen);
      if (gen != _processGen || audioPath == null) return; // Відмінено

      _statusMessage = '🎧 ${currentPoi.shownName}';
      notifyListeners();

      BackgroundService.updateNotification(
        'NotMiss — ${currentPoi.shownName}',
        'Now playing audio narration 🎧',
      );

      // "You are at a place": a vibration and a soft chime just before the voice, so the
      // narration never cuts in abruptly (the chime plays inside the same audio session).
      if (playArrivalCue) {
        unawaited(HapticFeedback.mediumImpact().catchError((_) {}));
        _audioService.armArrivalCue();
      }
      _publishNowPlaying(currentPoi, playing: true);
      await _playWithRetry(audioPath, () => gen != _processGen);
      if (gen != _processGen) return; // Відмінено
      _markListened(currentPoi);

      BackgroundService.updateNotification(
        'NotMiss — Walk in progress',
        'Voice guide is active. You\'ll be notified near each point.',
      );
    } catch (e) {
      if (gen == _processGen) {
        // The POI stays marked as triggered (unmarking would retry forever when offline),
        // but the card with the narration text stays on screen so nothing is lost.
        failed = true;
        _narrationFailed = true;
        debugPrint('[WalkController] Error processing POI ${currentPoi.name}: $e');
        _statusMessage = '📍 ${currentPoi.shownName} — озвучення недоступне, розповідь текстом';
        notifyListeners();
        BackgroundService.updateNotification(
          'NotMiss',
          'Narration available for ${currentPoi.name}.',
        );
      }
    } finally {
      await IosBackgroundTask.end();
      if (gen == _processGen) {
        _audioRequested = false;
        _isProcessing = false;
        // _activePoi is intentionally kept: the card with the text stays until the user
        // walks away (see _dismissStaleCard), starts another POI or closes it.
        if (_status == WalkStatus.walking && !failed && !keepStatus) {
          _statusMessage = L.t('Прогулянка — слухаю (${_proximityEvents.length} зафіксовано)', 'Walk — listening (${_proximityEvents.length} recorded)');
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
          _statusMessage = L.t('🔊 повторна спроба озвучення ($attempt/$ttsAttempts)…', '🔊 retrying the voice ($attempt/$ttsAttempts)…');
          notifyListeners();
          await Future.delayed(ttsRetryPause);
          if (isCancelled()) return null;
        }
      }
    }
    throw lastError!;
  }

  /// A story left on pause (by the user or by a phone call) must not block the guide forever:
  /// once the walker has left the place behind, it is dropped and new places can be narrated.
  void _dropAbandonedPause(Position pos) {
    final active = _activePoi;
    if (active == null || !isAudioPaused) return;
    final dist = Geolocator.distanceBetween(
      pos.latitude, pos.longitude, active.latitude, active.longitude,
    );
    if (dist > math.max(active.triggerRadius * 3, abandonedPauseM)) {
      debugPrint('[WalkController] Dropping paused narration of ${active.name}: left behind');
      unawaited(stopAudio());
    }
  }

  static const double abandonedPauseM = 150;

  /// A refused audio session or a stalled player gets one more try before the story is lost.
  Future<void> _playWithRetry(String audioPath, bool Function() isCancelled) async {
    try {
      await _audioService.play(audioPath);
    } on PlaybackFailed catch (e) {
      debugPrint('[WalkController] Playback failed, retrying: $e');
      await Future.delayed(playRetryPause);
      if (isCancelled()) return;
      await _audioService.play(audioPath);
    }
  }

  /// Pause before the second playback attempt (public so tests can shorten it).
  Duration playRetryPause = const Duration(milliseconds: 1500);

  /// Clears a finished card once the user has walked well away from its POI.
  void _dismissStaleCard(Position pos) {
    final active = _activePoi;
    if (active == null || _isProcessing || isAudioActive) return;
    final dist = Geolocator.distanceBetween(
      pos.latitude, pos.longitude, active.latitude, active.longitude,
    );
    if (dist > math.max(active.triggerRadius * 3, 80.0)) {
      _activePoi = null;
      _narrationFailed = false;
      if (_status == WalkStatus.walking) {
        _statusMessage = L.t('Прогулянка — слухаю (${_proximityEvents.length} зафіксовано)', 'Walk — listening (${_proximityEvents.length} recorded)');
      }
    }
  }

  @visibleForTesting
  Future<void> debugProcessPoi(Poi poi, Position pos) {
    _currentPosition ??= pos;
    return _processPoi(poi, pos);
  }

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
    unawaited(_nowPlaying.clear());
    unawaited(_liveActivity.end());
    _locationService.dispose();
    _audioService.dispose();
    _researchService.dispose();
    BackgroundService.stop();
    super.dispose();
  }
}
