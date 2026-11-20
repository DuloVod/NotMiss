import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

/// A point on the earth, kept free of any map package so the maths can be tested alone.
class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);

  @override
  bool operator ==(Object other) => other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);
}

/// A walking way to a chosen place. [straight] means no real route was found (offline, no
/// footpath…): the line is then a plain straight line and the distance is "as the crow flies".
class WalkRoute {
  final List<GeoPoint> points;
  final bool straight;
  const WalkRoute(this.points, {this.straight = false});

  /// A route made of just the two ends.
  factory WalkRoute.direct(GeoPoint from, GeoPoint to) => WalkRoute([from, to], straight: true);
}

/// Simple walking navigation: where to go, how far it still is, how long it takes.
///
/// The way itself comes from the public OpenStreetMap walking router (routing.openstreetmap.de).
/// It is asked only when the user taps "Go here", and only the two end points are sent: no
/// identifier, nothing else. Without an answer the app falls back to a straight line.
class NavigationService {
  NavigationService({http.Client? client, this.host = defaultHost}) : _client = client;

  static const String defaultHost = 'https://routing.openstreetmap.de/routed-foot';

  final http.Client? _client;
  final String host;

  /// Average pace of a person on foot, m/s (≈ 4.8 km/h).
  static const double walkSpeed = 1.33;

  /// Closer than this the user has arrived, metres.
  static const double arrivalRadius = 25;

  /// Further than this from the line the way is asked for again, metres.
  static const double offRouteDistance = 60;

  static const double _earth = 6371000;

  /// A walking route from [from] to [to], or null when none could be found.
  Future<WalkRoute?> fetchRoute(GeoPoint from, GeoPoint to) async {
    final client = _client ?? http.Client();
    try {
      final uri = Uri.parse('$host/route/v1/foot/${from.lng},${from.lat};${to.lng},${to.lat}'
          '?overview=full&geometries=geojson&steps=false');
      final res = await client.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return parseRoute(res.body);
    } catch (e) {
      debugPrint('[Navigation] route failed: $e');
      return null;
    } finally {
      if (_client == null) client.close();
    }
  }

  /// Reads an OSRM-style answer. Null when there is no usable way in it.
  static WalkRoute? parseRoute(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map || json['code'] != 'Ok') return null;
      final routes = json['routes'];
      if (routes is! List || routes.isEmpty) return null;
      final coords = (routes.first as Map)['geometry']?['coordinates'];
      if (coords is! List) return null;
      final points = <GeoPoint>[
        for (final c in coords)
          if (c is List && c.length >= 2) GeoPoint((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ];
      return points.length >= 2 ? WalkRoute(points) : null;
    } catch (_) {
      return null;
    }
  }

  /// Distance between two points, metres (haversine).
  static double distance(GeoPoint a, GeoPoint b) {
    final dLat = _rad(b.lat - a.lat);
    final dLng = _rad(b.lng - a.lng);
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.pow(math.sin(dLng / 2), 2);
    return 2 * _earth * math.asin(math.min(1, math.sqrt(h)));
  }

  /// Direction from [a] to [b], degrees clockwise from north (0..360).
  static double bearing(GeoPoint a, GeoPoint b) {
    final dLng = _rad(b.lng - a.lng);
    final y = math.sin(dLng) * math.cos(_rad(b.lat));
    final x = math.cos(_rad(a.lat)) * math.sin(_rad(b.lat)) -
        math.sin(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Where on the route the user is: the nearest segment, how far from the line, and what is
  /// left to walk along the line from there.
  static RouteProgress progress(WalkRoute route, GeoPoint user) {
    final pts = route.points;
    if (pts.length < 2) {
      return RouteProgress(offRoute: 0, remaining: pts.isEmpty ? 0 : distance(user, pts.last), next: pts.isEmpty ? user : pts.last);
    }
    var bestOff = double.infinity;
    var bestIndex = 0;
    var bestFoot = pts.first;
    for (var i = 0; i < pts.length - 1; i++) {
      final foot = _nearestOnSegment(user, pts[i], pts[i + 1]);
      final d = distance(user, foot);
      if (d < bestOff) {
        bestOff = d;
        bestIndex = i;
        bestFoot = foot;
      }
    }
    var remaining = distance(bestFoot, pts[bestIndex + 1]);
    for (var i = bestIndex + 1; i < pts.length - 1; i++) {
      remaining += distance(pts[i], pts[i + 1]);
    }
    // The arrow points at the line a little ahead, not at the closest spot (which would make
    // it swing round while walking along a road).
    var next = pts[bestIndex + 1];
    var ahead = distance(bestFoot, next);
    var i = bestIndex + 1;
    while (ahead < 20 && i < pts.length - 1) {
      ahead += distance(pts[i], pts[i + 1]);
      i++;
      next = pts[i];
    }
    return RouteProgress(offRoute: bestOff, remaining: remaining + bestOff, next: next);
  }

  /// Minutes to walk [meters] (never less than 1 while not there).
  static int minutes(double meters) => meters <= 0 ? 0 : math.max(1, (meters / walkSpeed / 60).round());

  /// Closest point to [p] on the segment [a]–[b] (small distances: flat approximation).
  static GeoPoint _nearestOnSegment(GeoPoint p, GeoPoint a, GeoPoint b) {
    final cos = math.cos(_rad(a.lat));
    final ax = a.lng * cos, ay = a.lat;
    final bx = b.lng * cos, by = b.lat;
    final px = p.lng * cos, py = p.lat;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return a;
    final t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
    return GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);
  }

  static double _rad(double deg) => deg * math.pi / 180;
}

/// How the user stands against a route.
class RouteProgress {
  /// Distance from the line, metres.
  final double offRoute;

  /// What is left to walk (to the line and then along it), metres.
  final double remaining;

  /// A point a little ahead on the route to point the arrow at.
  final GeoPoint next;

  const RouteProgress({required this.offRoute, required this.remaining, required this.next});
}
