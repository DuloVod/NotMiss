import '../l10n/app_lang.dart';
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
  /// The city's name in Ukrainian ("Львів"), whatever the app's language is: encyclopedia
  /// articles about a place are matched against it ("…у Львові").
  Future<String?> lookupLocalCity(double lat, double lng) async {
    final full = await lookupIn(lat, lng, AppLang.uk);
    return full?.split(',').first.trim();
  }

  /// "Lviv, Ukraine" / "Львів, Україна" for the point, in the app's language.
  Future<String?> lookup(double lat, double lng) => lookupIn(lat, lng, L.lang);

  Future<String?> lookupIn(double lat, double lng, AppLang lang) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'format': 'jsonv2',
        'lat': lat.toStringAsFixed(5),
        'lon': lng.toStringAsFixed(5),
        'zoom': '14', // at city level Nominatim names the municipality, not the city
        'accept-language': lang.code,
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
