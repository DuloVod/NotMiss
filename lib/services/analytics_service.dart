import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb, defaultTargetPlatform;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

/// Anonymous usage statistics (PostHog capture API over plain HTTP: no native SDK, no
/// advertising identifier, no tracking across other apps).
///
/// What is sent: an app-generated random id, event names and simple properties (place id and
/// name, kind, seconds, counts, language). What is never sent: coordinates, routes, the
/// user's own words (questions, report comments), name, e-mail, device advertising id.
///
/// Without a key, or when the user switched statistics off, every call does nothing.
class AnalyticsService {
  /// Keep equal to `version:` in pubspec.yaml (a test checks it).
  static const String appVersion = '1.1.5+20';

  static const String defaultHost = 'https://eu.i.posthog.com';

  /// Property names that could carry a position or the user's own words: dropped always.
  static final RegExp _forbiddenKey = RegExp(
    r'(^|_)(lat|lng|lon|latitude|longitude|coord|coords|coordinates|position|location|address|'
    r'email|phone|question|answer|comment|message|query|text)(_|$)',
    caseSensitive: false,
  );

  static const int maxQueue = 300;
  static const int batchSize = 20;
  static const int maxStringLength = 80;

  /// Gap of inactivity after which the next event starts a new session.
  static const Duration sessionGap = Duration(minutes: 30);

  AnalyticsService({
    String apiKey = '',
    String host = defaultHost,
    http.Client? client,
    Duration flushEvery = const Duration(seconds: 20),
    DateTime Function()? now,
    String? platform,
  })  : _apiKey = apiKey.trim(),
        _host = host.trim().isEmpty ? defaultHost : host.trim().replaceAll(RegExp(r'/+$'), ''),
        _client = client,
        _flushEvery = flushEvery,
        _now = now ?? DateTime.now,
        _platform = platform ?? _detectPlatform();

  final String _apiKey;
  final String _host;
  final http.Client? _client;
  final Duration _flushEvery;
  final DateTime Function() _now;
  final String _platform;

  String? _distinctId;
  bool _enabled = true;
  Map<String, Object?> _base = const {};
  final List<Map<String, Object?>> _queue = [];
  Timer? _timer;
  bool _flushing = false;
  bool _disposed = false;

  String? _sessionId;
  DateTime? _lastEventAt;
  DateTime? _foregroundSince;

  /// Whether events are really collected right now.
  bool get active => _apiKey.isNotEmpty && _enabled && _distinctId != null && !_disposed;

  bool get enabled => _enabled;
  int get queued => _queue.length;
  String? get distinctId => _distinctId;

  /// Who the events belong to and what is true of every event ([base]: language, version…).
  void configure({required String distinctId, required bool enabled, Map<String, Object?> base = const {}}) {
    _distinctId = distinctId;
    _base = base;
    setEnabled(enabled);
  }

  /// Updates a property that goes with every following event (e.g. the language).
  void setBase(String key, Object? value) {
    _base = {..._base, key: value};
  }

  void setEnabled(bool value) {
    _enabled = value;
    if (!value) {
      _queue.clear(); // switched off: nothing leaves the phone any more, nothing waits to
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Records [event]. Never throws and never waits for the network.
  void track(String event, [Map<String, Object?> props = const {}]) {
    if (!active) return;
    final now = _now();
    if (_sessionId == null || _lastEventAt == null || now.difference(_lastEventAt!) > sessionGap) {
      _sessionId = const Uuid().v4();
    }
    _lastEventAt = now;

    final clean = sanitize({..._base, ...props});
    _queue.add({
      'event': event,
      'distinct_id': _distinctId,
      'timestamp': now.toUtc().toIso8601String(),
      'properties': {
        ...clean,
        r'$session_id': _sessionId,
        r'$lib': 'notmiss-dart',
        'platform': _platform,
        'app_version': appVersion,
      },
    });
    if (_queue.length > maxQueue) _queue.removeRange(0, _queue.length - maxQueue);
    if (_queue.length >= batchSize) {
      unawaited(flush());
    } else {
      _timer ??= Timer(_flushEvery, () {
        _timer = null;
        unawaited(flush());
      });
    }
  }

  /// The app came to the foreground / went to the background: the time spent in it.
  void foreground() {
    if (_foregroundSince != null) return;
    _foregroundSince = _now();
    track('app_foreground');
  }

  void background() {
    final since = _foregroundSince;
    _foregroundSince = null;
    track('app_background', {
      if (since != null) 'foreground_seconds': _now().difference(since).inSeconds,
    });
    unawaited(flush());
  }

  /// Only simple, short, harmless values; nothing that looks like a position or free text.
  static Map<String, Object?> sanitize(Map<String, Object?> props) {
    final out = <String, Object?>{};
    props.forEach((key, value) {
      if (_forbiddenKey.hasMatch(key)) return;
      if (value == null) return;
      if (value is num) {
        if (value is double && (value.isNaN || value.isInfinite)) return;
        out[key] = value is double ? double.parse(value.toStringAsFixed(2)) : value;
      } else if (value is bool) {
        out[key] = value;
      } else if (value is String) {
        out[key] = value.length > maxStringLength ? value.substring(0, maxStringLength) : value;
      }
    });
    return out;
  }

  /// Sends what is waiting. On failure the events stay in the queue for the next try.
  Future<void> flush() async {
    if (_flushing || _queue.isEmpty || !active) return;
    _flushing = true;
    final batch = List<Map<String, Object?>>.from(_queue.take(100));
    try {
      final client = _client ?? http.Client();
      try {
        final res = await client
            .post(
              Uri.parse('$_host/batch/'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'api_key': _apiKey, 'batch': batch}),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          _queue.removeRange(0, batch.length.clamp(0, _queue.length));
        } else if (res.statusCode >= 400 && res.statusCode < 500) {
          // The server will never accept these (bad key…): do not keep them forever.
          _queue.removeRange(0, batch.length.clamp(0, _queue.length));
          debugPrint('[Analytics] rejected: ${res.statusCode}');
        }
      } finally {
        if (_client == null) client.close();
      }
    } catch (e) {
      debugPrint('[Analytics] send failed (will retry): $e');
    } finally {
      _flushing = false;
    }
    if (_queue.isNotEmpty && active && _timer == null) {
      _timer = Timer(_flushEvery, () {
        _timer = null;
        unawaited(flush());
      });
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  static String _detectPlatform() {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform.name; // iOS / android …
  }

  /// A new random id for the person (the app's own, not the phone's advertising id).
  static String newId() => const Uuid().v4();
}
