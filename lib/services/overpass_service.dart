import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb, visibleForTesting;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/poi.dart';

/// Loads POIs from the Overpass API (OpenStreetMap) and caches them locally.
///
/// Features:
///   - Searches within 500m radius (configurable).
///   - Extracts Wikidata IDs and full OSM tags for downstream research.
///   - Two-tier cache: in-memory + disk (JSON file via path_provider).
///   - Dynamic reload: re-fetches when user moves 250m from last query center.
///   - Rate limiting with exponential backoff on errors.
///   - Graceful fallback to cache on network failure.
class OverpassService {
  /// Radius around the user's position to search for POIs (metres).
  static const double searchRadiusM = 1000.0;

  /// Trigger radius for OSM POIs (metres).
  static const double defaultTriggerRadiusM = 40.0;

  /// Overpass API endpoints (fallback sequence, fastest and most reliable first).
  static const List<String> _endpoints = [
    'https://overpass.openstreetmap.fr/api/interpreter', // OpenStreetMap France (fastest, ~300ms)
    'https://z.overpass-api.de/api/interpreter',          // FOSSGIS mirror Z
    'https://overpass-api.de/api/interpreter',            // FOSSGIS main instance
    'https://lz4.overpass-api.de/api/interpreter',        // FOSSGIS mirror LZ4
    'https://overpass.kumi.systems/api/interpreter',      // Kumi Systems mirror
  ];

  /// Last successfully used endpoint to avoid retrying slower servers.
  String? _preferredEndpoint;

  /// Cache file name.
  static const String _cacheFileName = 'osm_poi_cache.json';

  /// How far user can move before we re-fetch (metres).
  static const double _cacheValidRadiusM = 250.0;

  /// Minimum time between Overpass requests.
  static const Duration _minRequestInterval = Duration(seconds: 10);

  /// Max pause between retries after failures (kept short: a walker must not wait minutes).
  static const int _maxBackoffSeconds = 20;

  /// Endpoints are tried in a staggered race: the next mirror starts this long after the
  /// previous one if nothing has answered yet, so one dead server costs seconds, not 12 s each.
  final Duration staggerDelay;

  /// How long one mirror may take. The public servers are often overloaded: a small query then
  /// needs 15–25 s, and a client that gives up at 12 s never gets any answer.
  final Duration requestTimeout;

  OverpassService({
    this.staggerDelay = const Duration(seconds: 2),
    this.requestTimeout = const Duration(seconds: 28),
  });

  /// The cached list comes from the quick, reduced search: the full one follows soon.
  bool _partial = false;

  /// Radius of the quick search (metres).
  static const double quickRadiusM = 450.0;

  /// True when the last [loadPois] returned an empty list because the network / all mirrors
  /// failed (as opposed to a genuinely empty area). Callers must retry instead of
  /// treating the area as loaded.
  bool lastLoadFailed = false;

  // In-memory cache
  List<Poi>? _cachedPois;
  double? _cacheCenterLat;
  double? _cacheCenterLng;
  DateTime? _lastRequestTime;
  int _consecutiveErrors = 0;

  /// Whether we need to reload POIs because user moved far enough.
  bool shouldReload(double lat, double lng) {
    if (_cachedPois == null) return true;
    if (_partial) return true; // the rate limit spaces the full search out
    if (_cacheCenterLat == null || _cacheCenterLng == null) return true;
    final dist = Geolocator.distanceBetween(
      lat, lng, _cacheCenterLat!, _cacheCenterLng!,
    );
    return dist > _cacheValidRadiusM;
  }

  /// Load POIs near [lat], [lng].
  ///
  /// Returns cached POIs if available and user hasn't moved too far.
  /// If [force] is true, ignores local caches and queries Overpass directly.
  Future<List<Poi>> loadPois(double lat, double lng, {bool force = false}) async {
    // 1. Check in-memory cache
    if (!force && _cachedPois != null && !shouldReload(lat, lng)) {
      debugPrint('[OverpassService] Using in-memory cache: '
          '${_cachedPois!.length} POIs');
      lastLoadFailed = false;
      return _cachedPois!;
    }

    // 2. Check disk cache (valid only for the place it was fetched for)
    List<Poi>? diskPois;
    if (!force) {
      diskPois = await _loadFromDisk();
      if (diskPois != null && _isNearCacheCenter(lat, lng)) {
        _cachedPois = diskPois;
        lastLoadFailed = false;
        debugPrint('[OverpassService] Using disk cache: '
            '${diskPois.length} POIs');
        return diskPois;
      }
      // A cache from another place must never be served as a fallback either.
      if (diskPois != null && !_isNearCacheCenter(lat, lng, maxM: 1500)) diskPois = null;
    }

    // 3. Rate limiting check
    if (_lastRequestTime != null) {
      final elapsed = DateTime.now().difference(_lastRequestTime!);
      // Exponential backoff on consecutive errors
      final backoff = _consecutiveErrors > 0
          ? Duration(seconds: (3 * (1 << _consecutiveErrors.clamp(0, 4))).clamp(3, _maxBackoffSeconds))
          : _minRequestInterval;
      if (elapsed < backoff) {
        debugPrint('[OverpassService] Rate limited, using cache');
        if (_cachedPois != null) return _cachedPois!;
        if (diskPois != null) return diskPois;
        debugPrint('[OverpassService] Rate limited and no cache available, returning empty list');
        lastLoadFailed = true;
        return [];
      }
    }

    // 4. Fetch from Overpass
    try {
      _lastRequestTime = DateTime.now();
      // First search in an area: the quick one, so the walker has points within seconds even when
      // the servers are slow. The full search follows (see [shouldReload]).
      final quickFirst = _cachedPois == null || _isFarFromCache(lat, lng);
      List<Poi> pois;
      var partial = false;
      if (quickFirst) {
        pois = await _fetchFromOverpass(lat, lng, quick: true);
        partial = true;
      } else {
        try {
          pois = await _fetchFromOverpass(lat, lng);
        } catch (e) {
          debugPrint('[OverpassService] Full search failed, trying the quick one: $e');
          pois = await _fetchFromOverpass(lat, lng, quick: true);
          partial = true;
        }
      }
      _partial = partial;
      _cachedPois = pois;
      _cacheCenterLat = lat;
      _cacheCenterLng = lng;
      _consecutiveErrors = 0;
      lastLoadFailed = false;
      await _saveToDisk(pois, lat, lng);
      debugPrint('[OverpassService] Fetched from Overpass: ${pois.length} POIs'
          '${partial ? ' (quick search, full one follows)' : ''}');
      return pois;
    } catch (e) {
      _consecutiveErrors++;
      debugPrint('[OverpassService] Overpass fetch failed '
          '(error #$_consecutiveErrors): $e');
      // Fall back to any existing cache
      if (_cachedPois != null) return _cachedPois!;
      if (diskPois != null) return diskPois;
      lastLoadFailed = true;
      return []; // Return empty list rather than crashing on network outage
    }
  }

  bool _isNearCacheCenter(double lat, double lng, {double maxM = _cacheValidRadiusM}) {
    if (_cacheCenterLat == null || _cacheCenterLng == null) return false;
    return Geolocator.distanceBetween(lat, lng, _cacheCenterLat!, _cacheCenterLng!) <= maxM;
  }

  /// Build and execute the Overpass QL query with fallback support.
  bool _isFarFromCache(double lat, double lng) {
    if (_cacheCenterLat == null || _cacheCenterLng == null) return true;
    return Geolocator.distanceBetween(lat, lng, _cacheCenterLat!, _cacheCenterLng!) > _cacheValidRadiusM;
  }

  Future<List<Poi>> _fetchFromOverpass(double lat, double lng, {bool quick = false}) async {
    final query = quick ? _buildQuickQuery(lat, lng, quickRadiusM) : _buildQuery(lat, lng, searchRadiusM);
    final bodyStr = 'data=${Uri.encodeComponent(query)}';
    final headers = {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': 'NotMiss/1.1 (https://github.com/DuloVod/NotMiss; walking tour guide app)',
    };

    // Prioritize the server that succeeded last time
    final candidateEndpoints = List<String>.from(_endpoints);
    if (_preferredEndpoint != null && candidateEndpoints.contains(_preferredEndpoint)) {
      candidateEndpoints.remove(_preferredEndpoint);
      candidateEndpoints.insert(0, _preferredEndpoint!);
    }

    final errors = <String>[];
    final done = Completer<List<dynamic>>();
    var pending = candidateEndpoints.length;

    Future<void> attempt(String endpoint) async {
      try {
        debugPrint('[OverpassService] Trying endpoint: $endpoint');
        final response = await http
            .post(Uri.parse(endpoint), headers: headers, body: bodyStr)
            .timeout(requestTimeout);
        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final elements = json['elements'] as List<dynamic>? ?? [];
          if (!done.isCompleted) {
            _preferredEndpoint = endpoint; // Stick to the server that responded first
            debugPrint('[OverpassService] Success from $endpoint (${elements.length} elements)');
            done.complete(elements);
          }
          return;
        }
        final err = 'HTTP ${response.statusCode}: ${response.reasonPhrase}';
        debugPrint('[OverpassService] Endpoint failed ($endpoint): $err');
        errors.add('$endpoint: $err');
      } catch (e) {
        debugPrint('[OverpassService] Endpoint error ($endpoint): $e');
        errors.add('$endpoint: $e');
      }
      if (endpoint == _preferredEndpoint) _preferredEndpoint = null;
      if (--pending == 0 && !done.isCompleted) {
        done.completeError(HttpException('All Overpass endpoints failed:\n${errors.join('\n')}'));
      }
    }

    // Staggered race: next mirror starts if nobody answered within [staggerDelay]
    // (or immediately when the previous one has already failed).
    for (var i = 0; i < candidateEndpoints.length && !done.isCompleted; i++) {
      unawaited(attempt(candidateEndpoints[i]));
      await Future.any([done.future.then((_) {}, onError: (_) {}), Future.delayed(staggerDelay)]);
    }
    final elements = await done.future;

    return _parseElements(elements);
  }

  /// Light search for a slow server: the kinds of places people actually walk up to, nearby.
  String _buildQuickQuery(double lat, double lng, double radiusM) {
    final r = radiusM.toInt();
    return '''
[out:json][timeout:25];
(
  nwr["tourism"~"attraction|museum|viewpoint|artwork|gallery"](around:$r,$lat,$lng);
  nwr["historic"](around:$r,$lat,$lng);
  nwr["amenity"~"place_of_worship|fountain|theatre|library|monastery|arts_centre"](around:$r,$lat,$lng);
  nwr["leisure"~"park|garden"](around:$r,$lat,$lng);
  nwr["place"="square"](around:$r,$lat,$lng);
  nwr["wikidata"](around:$r,$lat,$lng);
);
out center;
''';
  }

  /// Overpass QL query: get named POIs of relevant categories within search radius.
  String _buildQuery(double lat, double lng, double radiusM) {
    final r = radiusM.toInt();
    return '''
[out:json][timeout:25];
(
  // Tourism & Attractions
  node["tourism"~"attraction|museum|viewpoint|artwork|information|gallery|theme_park|zoo"](around:$r,$lat,$lng);
  way["tourism"~"attraction|museum|viewpoint|artwork|information|gallery|theme_park|zoo"](around:$r,$lat,$lng);
  relation["tourism"~"attraction|museum|viewpoint|artwork|information|gallery|theme_park|zoo"](around:$r,$lat,$lng);

  // Historic & Heritage
  node["historic"](around:$r,$lat,$lng);
  way["historic"](around:$r,$lat,$lng);
  relation["historic"](around:$r,$lat,$lng);
  node["heritage"](around:$r,$lat,$lng);
  way["heritage"](around:$r,$lat,$lng);

  // Leisure & Nature
  node["leisure"~"garden|park|nature_reserve"](around:$r,$lat,$lng);
  way["leisure"~"garden|park|nature_reserve"](around:$r,$lat,$lng);
  node["natural"~"tree|spring|peak|cave_entrance|rock|cliff|water"](around:$r,$lat,$lng);
  way["natural"~"water|wood"](around:$r,$lat,$lng);

  // Amenities & Cultural Places
  node["amenity"~"place_of_worship|fountain|theatre|cinema|library|monastery|arts_centre|community_centre|planetarium|public_art"](around:$r,$lat,$lng);
  way["amenity"~"place_of_worship|fountain|theatre|cinema|library|monastery|arts_centre|community_centre|planetarium|public_art"](around:$r,$lat,$lng);

  // Architecture & Man-made Monuments/Towers
  node["man_made"~"tower|water_tower|obelisk|windmill|cross|lighthouse|monument"](around:$r,$lat,$lng);
  way["man_made"~"tower|water_tower|obelisk|windmill|cross|lighthouse|monument"](around:$r,$lat,$lng);
  node["building"~"church|cathedral|synagogue|mosque|castle|palace|manor|tower|ruins|historic|chapel|bell_tower"](around:$r,$lat,$lng);
  way["building"~"church|cathedral|synagogue|mosque|castle|palace|manor|tower|ruins|historic|chapel|bell_tower"](around:$r,$lat,$lng);

  // Railway heritage / miniature park trains
  node["railway"~"station|halt|miniature"](around:$r,$lat,$lng);
  way["railway"~"station|halt|miniature"](around:$r,$lat,$lng);

  // Squares and anything that has its own Wikidata entity (buildings, streets, universities…)
  nwr["place"="square"](around:$r,$lat,$lng);
  nwr["wikidata"](around:$r,$lat,$lng);
  nwr["wikipedia"](around:$r,$lat,$lng);
);
out bb;
''';
  }

  /// Objects with a Wikidata tag that are not places one can walk up to: routes, borders, whole
  /// districts, power lines. Plain map boards are not attractions either.
  static bool _isNotAPlace(Map<String, String> t) {
    if (t['type'] == 'route' || t['type'] == 'route_master' || t['type'] == 'boundary') return true;
    if (t.containsKey('route') || t.containsKey('boundary') || t.containsKey('admin_level')) return true;
    if (t.containsKey('network') && !t.containsKey('railway')) return true;
    final place = t['place'];
    if (place != null && place != 'square') return true;
    if (t.containsKey('power') || t.containsKey('waterway') || t.containsKey('landuse')) return true;
    final railway = t['railway'];
    if (railway != null && !const {'station', 'halt', 'miniature'}.contains(railway)) return true;
    if (t['tourism'] == 'information' && !t.containsKey('wikidata') && !t.containsKey('wikipedia')) {
      return true;
    }
    return false;
  }

  /// Half of the object's diagonal in metres, or null when it is a point / has bogus bounds.
  static double? _halfDiagonalM(Map<String, dynamic>? bounds) {
    if (bounds == null) return null;
    final minLat = (bounds['minlat'] as num?)?.toDouble();
    final minLon = (bounds['minlon'] as num?)?.toDouble();
    final maxLat = (bounds['maxlat'] as num?)?.toDouble();
    final maxLon = (bounds['maxlon'] as num?)?.toDouble();
    if (minLat == null || minLon == null || maxLat == null || maxLon == null) return null;
    if (minLat < -90 || maxLat > 90 || minLon < -180 || maxLon > 180) return null;
    return Geolocator.distanceBetween(minLat, minLon, maxLat, maxLon) / 2;
  }

  /// A big park or a long building: the walker reaches it long before its centre, so the trigger
  /// radius grows with the object's size (within limits).
  @visibleForTesting
  static double triggerRadiusFor(double? halfDiagonalM, Map<String, String> tags) {
    if (halfDiagonalM == null) return defaultTriggerRadiusM;
    final cap = tags.containsKey('highway') ? 120.0 : maxTriggerRadiusM;
    return (halfDiagonalM + 15).clamp(defaultTriggerRadiusM, cap);
  }

  static const double maxTriggerRadiusM = 350;

  /// One object can be mapped several times (a node and a way, nine segments of one street).
  /// Keeps the best-described entry per name within a distance.
  @visibleForTesting
  static List<Poi> dedupeByName(List<Poi> pois) {
    int score(Poi p) {
      final t = p.osmTags ?? const {};
      return (t.containsKey('wikidata') ? 4 : 0) + (t.containsKey('wikipedia') ? 2 : 0) + t.length.clamp(0, 20) ~/ 10;
    }

    final kept = <Poi>[];
    for (final p in pois) {
      final name = p.name.trim().toLowerCase();
      final maxD = (p.osmTags ?? const {}).containsKey('highway') ? 1500.0 : 150.0;
      final i = kept.indexWhere((k) =>
          k.name.trim().toLowerCase() == name &&
          Geolocator.distanceBetween(k.latitude, k.longitude, p.latitude, p.longitude) <= maxD);
      if (i == -1) {
        kept.add(p);
      } else if (score(p) > score(kept[i])) {
        kept[i] = p;
      }
    }
    return kept;
  }

  /// Parse Overpass JSON elements into Poi objects.
  List<Poi> _parseElements(List<dynamic> elements) {
    final pois = <Poi>[];
    final seenIds = <String>{};

    for (final el in elements) {
      final type = el['type'] as String?;
      final osmId = el['id'];
      if (type == null || osmId == null) continue;

      // Stable ID based on OSM type + id
      final id = 'osm_${type}_$osmId';
      if (seenIds.contains(id)) continue;

      final bounds = el['bounds'] as Map<String, dynamic>?;
      final halfDiagonal = _halfDiagonalM(bounds);

      // Get coordinates: nodes have lat/lon directly; ways/relations have center or bounds
      double? lat;
      double? lng;

      if (type == 'node') {
        lat = (el['lat'] as num?)?.toDouble();
        lng = (el['lon'] as num?)?.toDouble();
      } else {
        // way or relation — use center, or the middle of the bounds
        final center = el['center'] as Map<String, dynamic>?;
        if (center != null) {
          lat = (center['lat'] as num?)?.toDouble();
          lng = (center['lon'] as num?)?.toDouble();
        } else if (bounds != null && halfDiagonal != null) {
          lat = (((bounds['minlat'] as num) + (bounds['maxlat'] as num)) / 2).toDouble();
          lng = (((bounds['minlon'] as num) + (bounds['maxlon'] as num)) / 2).toDouble();
        }
      }

      if (lat == null || lng == null) continue;

      final rawTags = el['tags'] as Map<String, dynamic>? ?? {};
      final tags = rawTags.map((k, v) => MapEntry(k, v.toString()));

      final name = tags['name'] ??
          tags['name:uk'] ??
          tags['name:en'] ??
          tags['official_name'] ??
          tags['int_name'] ??
          tags['alt_name'] ??
          tags['loc_name'] ??
          tags['name:ru'];

      // Skip unnamed POIs
      if (name == null || name.isEmpty) continue;
      if (_isNotAPlace(tags)) continue;
      // Spans several kilometres (long routes, rivers): not something one "arrives at".
      if (halfDiagonal != null && halfDiagonal > 2500 && !tags.containsKey('leisure')) continue;
      seenIds.add(id);

      // Extract Wikidata ID if present
      final wikidataId = tags['wikidata'];

      // Build a short description from available tags
      final description = _buildDescription(tags);

      pois.add(Poi(
        id: id,
        name: name,
        latitude: lat,
        longitude: lng,
        triggerRadius: triggerRadiusFor(halfDiagonal, tags),
        shortDescription: description,
        facts: [],
        narrationText: '',
        sources: [
          PoiSource(
            title: '© OpenStreetMap contributors',
            url: 'https://www.openstreetmap.org/$type/$osmId',
          ),
        ],
        confidence: 'osm',
        wikidataId: wikidataId,
        osmTags: tags,
      ));
    }

    return dedupeByName(pois);
  }

  /// Build a human-readable description from OSM tags.
  String _buildDescription(Map<String, String> tags) {
    final parts = <String>[];

    final tourism = tags['tourism'];
    final historic = tags['historic'];
    final leisure = tags['leisure'];
    final amenity = tags['amenity'];

    if (tourism != null) parts.add(tourism);
    if (historic != null) parts.add('historic: $historic');
    if (leisure != null) parts.add(leisure);
    if (amenity != null) parts.add(amenity);

    final descr = tags['description'] ?? tags['description:uk'];
    if (descr != null) parts.add(descr);

    return parts.join(' · ');
  }

  // ── Disk caching ──────────────────────────────────────────────────────────

  Future<String> get _cachePath async {
    if (kIsWeb) return '';
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_cacheFileName';
  }

  Future<void> _saveToDisk(List<Poi> pois, double lat, double lng) async {
    if (kIsWeb) return;
    try {
      final path = await _cachePath;
      final data = {
        'center_lat': lat,
        'center_lng': lng,
        'timestamp': DateTime.now().toIso8601String(),
        'pois': pois.map((p) => <String, dynamic>{
          'id': p.id,
          'name': p.name,
          'latitude': p.latitude,
          'longitude': p.longitude,
          'triggerRadius': p.triggerRadius,
          'shortDescription': p.shortDescription,
          'confidence': p.confidence,
          'wikidataId': p.wikidataId,
          'osmTags': p.osmTags,
          'sources': p.sources.map((s) => <String, dynamic>{
            'title': s.title,
            'url': s.url,
          }).toList(),
        }).toList(),
      };
      await File(path).writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('[OverpassService] Failed to save cache: $e');
    }
  }

  Future<List<Poi>?> _loadFromDisk() async {
    if (kIsWeb) return null;
    try {
      final path = await _cachePath;
      final file = File(path);
      if (!await file.exists()) return null;

      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      // Check cache age — expire disk cache after 24 hours
      final timestampStr = data['timestamp'] as String?;
      if (timestampStr != null) {
        final timestamp = DateTime.tryParse(timestampStr);
        if (timestamp != null) {
          final age = DateTime.now().difference(timestamp);
          if (age > const Duration(hours: 24)) {
            debugPrint('[OverpassService] Disk cache expired (${age.inHours}h old), fetching fresh POIs');
            return null;
          }
        }
      }

      final rawPois = data['pois'] as List<dynamic>? ?? [];
      // If disk cache has fewer than 3 POIs, don't rely on it
      if (rawPois.length < 3) {
        debugPrint('[OverpassService] Disk cache has too few POIs (${rawPois.length}), re-fetching');
        return null;
      }

      _cacheCenterLat = (data['center_lat'] as num?)?.toDouble();
      _cacheCenterLng = (data['center_lng'] as num?)?.toDouble();
      return rawPois.map((p) {
        final m = p as Map<String, dynamic>;
        List<PoiSource> sources = [];
        final rawSources = m['sources'] as List<dynamic>?;
        if (rawSources != null) {
          for (final s in rawSources) {
            if (s is Map<String, dynamic>) {
              sources.add(PoiSource(
                title: s['title'] as String? ?? '',
                url: s['url'] as String? ?? '',
              ));
            }
          }
        }
        // Restore OSM tags
        Map<String, String>? osmTags;
        final rawTags = m['osmTags'] as Map<String, dynamic>?;
        if (rawTags != null) {
          osmTags = rawTags.map((k, v) => MapEntry(k, v.toString()));
        }

        return Poi(
          id: m['id'] as String,
          name: m['name'] as String,
          latitude: (m['latitude'] as num).toDouble(),
          longitude: (m['longitude'] as num).toDouble(),
          triggerRadius: (m['triggerRadius'] as num?)?.toDouble() ?? defaultTriggerRadiusM,
          shortDescription: m['shortDescription'] as String? ?? '',
          facts: [],
          narrationText: '',
          sources: sources,
          confidence: m['confidence'] as String? ?? 'osm',
          wikidataId: m['wikidataId'] as String?,
          osmTags: osmTags,
        );
      }).toList();
    } catch (e) {
      debugPrint('[OverpassService] Failed to load cache: $e');
      return null;
    }
  }

  /// Invalidate both in-memory and disk cache to force a clean Overpass search.
  Future<void> clearCache() async {
    _cachedPois = null;
    _cacheCenterLat = null;
    _cacheCenterLng = null;
    _lastRequestTime = null;
    _consecutiveErrors = 0;
    if (!kIsWeb) {
      try {
        final path = await _cachePath;
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('[OverpassService] Failed to delete disk cache: $e');
      }
    }
  }
}
