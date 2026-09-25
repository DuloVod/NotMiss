import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../models/destination.dart';
import '../models/poi.dart';
import '../services/location_service.dart';
import '../services/poi_engine.dart';
import '../services/content_service.dart';
import '../services/ai_service.dart';
import '../services/tts_service.dart';
import '../services/audio_player_service.dart';

enum WalkStatus { idle, walking, stopped }

/// Central state for an active walk session.
///
/// Coordinates all services: location → POI detection → narration → TTS → audio.
class WalkController extends ChangeNotifier {
  final Destination destination;
  final LocationService _locationService;
  final PoiEngine _poiEngine;
  final ContentService _contentService;
  final AiService _aiService;
  final TtsService _ttsService;
  final AudioPlayerService _audioService;

  WalkStatus _status = WalkStatus.idle;
  Position? _currentPosition;
  Poi? _activePoi;
  String? _statusMessage;
  bool _isProcessing = false; // prevents concurrent POI processing

  StreamSubscription<Position>? _positionSub;

  WalkController({
    required this.destination,
    required String apiKey,
    LocationService? locationService,
    PoiEngine? poiEngine,
    ContentService? contentService,
    AiService? aiService,
    TtsService? ttsService,
    AudioPlayerService? audioService,
  })  : _locationService = locationService ?? LocationService(),
        _poiEngine = poiEngine ?? PoiEngine(),
        _contentService = contentService ?? ContentService(),
        _aiService = aiService ?? AiService(apiKey: apiKey),
        _ttsService = ttsService ?? TtsService(apiKey: apiKey),
        _audioService = audioService ?? AudioPlayerService();

  WalkStatus get status => _status;
  Position? get currentPosition => _currentPosition;
  Poi? get activePoi => _activePoi;
  String? get statusMessage => _statusMessage;
  bool get isPlaying => _audioService.isPlaying;
  Set<String> get triggeredPoiIds => _poiEngine.triggeredPoiIds;

  Future<void> startWalk() async {
    final granted = await _locationService.requestPermission();
    if (!granted) {
      _statusMessage = 'Location permission required to start a walk.';
      notifyListeners();
      return;
    }

    _poiEngine.resetSession();
    _status = WalkStatus.walking;
    _activePoi = null;
    _statusMessage = 'Walking — listening for nearby places…';
    notifyListeners();

    _locationService.start();
    _positionSub = _locationService.positionStream.listen(_onPosition);
  }

  void stopWalk() {
    _positionSub?.cancel();
    _positionSub = null;
    _locationService.stop();
    _audioService.stop();
    _status = WalkStatus.stopped;
    _statusMessage = 'Walk ended. ${_poiEngine.triggeredPoiIds.length} place(s) visited.';
    notifyListeners();
  }

  Future<void> _onPosition(Position pos) async {
    _currentPosition = pos;
    notifyListeners();

    if (_isProcessing) return;

    final poi = _poiEngine.findTriggerablePoi(
      destination.pois,
      pos.latitude,
      pos.longitude,
    );

    if (poi == null) return;

    // Mark immediately to prevent re-entry while we process
    _poiEngine.markTriggered(poi.id);
    _isProcessing = true;
    _activePoi = poi;
    _statusMessage = '📍 ${poi.name} — generating narration…';
    notifyListeners();

    try {
      // M4: try AI narration, fall back to static
      final aiText = await _aiService.generateNarration(poi);
      final narration = _contentService.getNarration(poi, aiText: aiText);

      _statusMessage = '🔊 ${poi.name} — converting to speech…';
      notifyListeners();

      final audioPath = await _ttsService.synthesize(narration, poi.id);

      _statusMessage = '🎧 ${poi.name}';
      notifyListeners();

      await _audioService.play(audioPath);
    } catch (e) {
      _statusMessage = '⚠️ Could not play narration for ${poi.name}: $e';
      notifyListeners();
    } finally {
      _isProcessing = false;
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _locationService.dispose();
    _audioService.dispose();
    super.dispose();
  }
}
