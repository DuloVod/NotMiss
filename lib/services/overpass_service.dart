import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
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

  // In-memory cache
  List<Poi>? _cachedPois;
  double? _cacheCenterLat;
  double? _cacheCenterLng;
  DateTime? _lastRequestTime;
  int _consecutiveErrors = 0;

  /// Whether we need to reload POIs because user moved far enough.
  bool shouldReload(double lat, double lng) {
    if (_cachedPois == null) return true;
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
      return _cachedPois!;
    }

    // 2. Check disk cache
    List<Poi>? diskPois;
    if (!force) {
      diskPois = await _loadFromDisk();
      if (diskPois != null && !shouldReload(lat, lng)) {
        _cachedPois = diskPois;
        debugPrint('[OverpassService] Using disk cache: '
            '${diskPois.length} POIs');
        return diskPois;
      }
    }

    // 3. Rate limiting check
    if (_lastRequestTime != null) {
      final elapsed = DateTime.now().difference(_lastRequestTime!);
      // Exponential backoff on consecutive errors
      final backoff = _consecutiveErrors > 0
          ? Duration(seconds: _minRequestInterval.inSeconds *
              (1 << _consecutiveErrors.clamp(0, 5)))
          : _minRequestInterval;
      if (elapsed < backoff) {
        debugPrint('[OverpassService] Rate limited, using cache');
        if (_cachedPois != null) return _cachedPois!;
        if (diskPois != null) return diskPois;
        debugPrint('[OverpassService] Rate limited and no cache available, returning empty list');
        return [];
      }
    }

    // 4. Fetch from Overpass
    try {
      _lastRequestTime = DateTime.now();
      final pois = await _fetchFromOverpass(lat, lng);
      _cachedPois = pois;
      _cacheCenterLat = lat;
      _cacheCenterLng = lng;
      _consecutiveErrors = 0;
      await _saveToDisk(pois, lat, lng);
      debugPrint('[OverpassService] Fetched from Overpass: ${pois.length} POIs');
      return pois;
    } catch (e) {
      _consecutiveErrors++;
      debugPrint('[OverpassService] Overpass fetch failed '
          '(error #$_consecutiveErrors): $e');
      // Fall back to any existing cache
      if (_cachedPois != null) return _cachedPois!;
      if (diskPois != null) return diskPois;
      return []; // Return empty list rather than crashing on network outage
    }
  }

  /// Build and execute the Overpass QL query with fallback support.
  Future<List<Poi>> _fetchFromOverpass(double lat, double lng) async {
    final query = _buildQuery(lat, lng, searchRadiusM);
    final bodyStr = 'data=${Uri.encodeComponent(query)}';
    final headers = {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': 'NotMiss/0.3.0 (walking tour guide app)',
    };

    // Prioritize the server that succeeded last time
    final candidateEndpoints = List<String>.from(_endpoints);
    if (_preferredEndpoint != null && candidateEndpoints.contains(_preferredEndpoint)) {
      candidateEndpoints.remove(_preferredEndpoint);
      candidateEndpoints.insert(0, _preferredEndpoint!);
    }

    List<dynamic>? elements;
    final errors = <String>[];

    for (final endpoint in candidateEndpoints) {
      try {
        debugPrint('[OverpassService] Trying endpoint: $endpoint');
        final response = await http
            .post(
              Uri.parse(endpoint),
              headers: headers,
              body: bodyStr,
            )
            .timeout(const Duration(seconds: 12)); // 12s timeout for Overpass 10s query

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          elements = json['elements'] as List<dynamic>? ?? [];
          _preferredEndpoint = endpoint; // Stick to the server that responded successfully
          debugPrint('[OverpassService] Success from $endpoint (${elements.length} elements)');
          break; // Success, exit the loop
        } else {
          final err = 'HTTP ${response.statusCode}: ${response.reasonPhrase}';
          debugPrint('[OverpassService] Endpoint failed ($endpoint): $err');
          errors.add('$endpoint: $err');
          if (endpoint == _preferredEndpoint) _preferredEndpoint = null;
        }
      } catch (e) {
        debugPrint('[OverpassService] Endpoint error ($endpoint): $e');
        errors.add('$endpoint: $e');
        if (endpoint == _preferredEndpoint) _preferredEndpoint = null;
      }
    }

    if (elements == null) {
      throw HttpException('All Overpass endpoints failed:\n${errors.join('\n')}');
    }

    return _parseElements(elements);
  }

  /// Overpass QL query: get named POIs of relevant categories within search radius.
  String _buildQuery(double lat, double lng, double radiusM) {
    final r = radiusM.toInt();
    return '''
[out:json][timeout:15];
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
);
out center;
''';
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

      // Get coordinates: nodes have lat/lon directly; ways/relations have center
      double? lat;
      double? lng;

      if (type == 'node') {
        lat = (el['lat'] as num?)?.toDouble();
        lng = (el['lon'] as num?)?.toDouble();
      } else {
        // way or relation — use center
        final center = el['center'] as Map<String, dynamic>?;
        if (center != null) {
          lat = (center['lat'] as num?)?.toDouble();
          lng = (center['lon'] as num?)?.toDouble();
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
        triggerRadius: defaultTriggerRadiusM,
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

    return pois;
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
