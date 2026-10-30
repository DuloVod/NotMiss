import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// Works out which city / country the user is in (reverse geocoding via OpenStreetMap
/// Nominatim), so the AI never mixes up places with the same name from another city.
class PlaceContextService {
  /// Result for one position is reused within this distance.
  static const double reuseRadiusM = 5000;

  /// "Львів, Україна" for the given point; null when it cannot be determined.
  Future<String?> lookup(double lat, double lng) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'format': 'jsonv2',
        'lat': lat.toStringAsFixed(5),
        'lon': lng.toStringAsFixed(5),
        'zoom': '10',
        'accept-language': 'uk',
      });
      final res = await http
          .get(uri, headers: {'User-Agent': 'NotMiss/0.2 (com.dulo.notmiss)'})
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      return parse(utf8.decode(res.bodyBytes));
    } catch (e) {
      debugPrint('[PlaceContextService] lookup failed: $e');
      return null;
    }
  }

  /// Extracts "city, country" from a Nominatim reverse-geocoding response.
  static String? parse(String body) {
    try {
      final json = jsonDecode(body);
      final address = (json is Map ? json['address'] : null) as Map?;
      if (address == null) return null;
      String? pick(List<String> keys) {
        for (final k in keys) {
          final v = address[k];
          if (v is String && v.trim().isNotEmpty) return v.trim();
        }
        return null;
      }

      final place = pick(['city', 'town', 'village', 'municipality', 'county', 'state']);
      final country = pick(['country']);
      if (place == null && country == null) return null;
      return [if (place != null) place, if (country != null) country].join(', ');
    } catch (_) {
      return null;
    }
  }
}
