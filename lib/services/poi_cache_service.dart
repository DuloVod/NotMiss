import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import '../models/enriched_poi.dart';

/// Persistent cache for enriched POI research data.
///
/// Stores EnrichedPoi objects as JSON files in the app's
/// documents directory. Each POI is a separate entry in a
/// single JSON file for simplicity.
class PoiCacheService {
  static const _cacheFileName = 'poi_research_cache.json';

  /// In-memory index: poiId -> EnrichedPoi
  final Map<String, EnrichedPoi> _cache = {};
  bool _loaded = false;

  /// Load cache from disk. Call once at startup.
  Future<void> init() async {
    if (_loaded || kIsWeb) return;
    try {
      final path = await _cachePath;
      final file = File(path);
      if (!await file.exists()) {
        _loaded = true;
        return;
      }
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final pois = data['pois'] as Map<String, dynamic>? ?? {};
      for (final entry in pois.entries) {
        _cache[entry.key] = EnrichedPoi.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
      _loaded = true;
      debugPrint('[PoiCacheService] Loaded ${_cache.length} enriched POIs from cache');
    } catch (e) {
      debugPrint('[PoiCacheService] Failed to load cache: $e');
      _loaded = true; // Don't retry on every access
    }
  }

  /// Get enriched data for a POI, or null if not cached.
  EnrichedPoi? get(String poiId) => _cache[poiId];

  /// Store or update enriched POI data.
  Future<void> put(EnrichedPoi enriched) async {
    _cache[enriched.poiId] = enriched;
    await _saveToDisk();
  }

  /// Store multiple enriched POIs at once.
  Future<void> putAll(List<EnrichedPoi> enrichedPois) async {
    for (final ep in enrichedPois) {
      _cache[ep.poiId] = ep;
    }
    await _saveToDisk();
  }

  /// Check if a POI exists in cache and is marked complete.
  bool isComplete(String poiId) {
    final cached = _cache[poiId];
    return cached != null && cached.isResearchComplete;
  }

  /// Check if a POI needs research (not started or failed with retry allowed).
  bool needsResearch(String poiId) {
    final cached = _cache[poiId];
    if (cached == null) return true;
    if (cached.researchStatus == ResearchStatus.notStarted) return true;
    if (cached.researchStatus == ResearchStatus.queued) return true;
    if (cached.researchStatus == ResearchStatus.inProgress) {
      // If stuck in progress for over 5 minutes (e.g. app crashed), allow retry
      if (cached.lastResearchedAt != null) {
        final elapsed = DateTime.now().difference(cached.lastResearchedAt!);
        return elapsed > const Duration(minutes: 5);
      }
      return true; // No timestamp = stuck, allow retry
    }
    if (cached.researchStatus == ResearchStatus.failed) {
      // Allow retry if last attempt was more than 1 hour ago
      if (cached.lastResearchedAt != null) {
        final elapsed = DateTime.now().difference(cached.lastResearchedAt!);
        return elapsed > const Duration(hours: 1);
      }
      return true;
    }
    return false;
  }

  /// Get all cached POIs within radius of a point.
  List<EnrichedPoi> getNearby(double lat, double lng, double radiusM) {
    return _cache.values.where((ep) {
      final dist = Geolocator.distanceBetween(lat, lng, ep.latitude, ep.longitude);
      return dist <= radiusM;
    }).toList();
  }

  /// Get all cached POIs.
  List<EnrichedPoi> getAll() => List.unmodifiable(_cache.values.toList());

  /// Number of cached POIs.
  int get length => _cache.length;

  Future<String> get _cachePath async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_cacheFileName';
  }

  Timer? _saveTimer;

  Future<void> _saveToDisk() async {
    if (kIsWeb) return;
    
    // Debounce disk writes to avoid IO thrashing when many POIs are processed
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () async {
      try {
        final path = await _cachePath;
        final data = {
          'version': 1,
          'updated_at': DateTime.now().toIso8601String(),
          'pois': _cache.map((k, v) => MapEntry(k, v.toJson())),
        };
        await File(path).writeAsString(jsonEncode(data));
      } catch (e) {
        debugPrint('[PoiCacheService] Failed to save cache: $e');
      }
    });
  }

  /// Flush pending writes and cancel timers. Call when the service is no longer needed.
  Future<void> dispose() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    // Flush any pending data to disk immediately
    if (!kIsWeb && _cache.isNotEmpty) {
      try {
        final path = await _cachePath;
        final data = {
          'version': 1,
          'updated_at': DateTime.now().toIso8601String(),
          'pois': _cache.map((k, v) => MapEntry(k, v.toJson())),
        };
        await File(path).writeAsString(jsonEncode(data));
      } catch (e) {
        debugPrint('[PoiCacheService] Failed to flush cache on dispose: $e');
      }
    }
  }
}
