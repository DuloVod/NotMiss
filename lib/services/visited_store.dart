import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';

/// A place the user has physically passed and/or listened to.
class VisitedPlace {
  final String id;
  final String name;

  /// [PoiKind] name, kept so the list can show the right icon without loading the place.
  final String kind;

  /// The user came within the place's trigger radius (walked past it).
  final bool passed;

  /// The narration was played to the end.
  final bool listened;

  const VisitedPlace(this.id, this.name, this.kind, {this.passed = true, this.listened = false});

  VisitedPlace copyWith({bool? passed, bool? listened}) =>
      VisitedPlace(id, name, kind, passed: passed ?? this.passed, listened: listened ?? this.listened);
}

/// Remembers which places the user has passed and listened to, across walks and restarts.
///
/// Keeps working in memory when the disk is unavailable (web, tests), so a storage problem
/// can never get in the way of a walk.
class VisitedStore {
  static const _fileName = 'visited_pois.json';

  final Future<String> Function()? _pathProvider;

  /// Insertion-ordered: the last entry is the most recent.
  final Map<String, VisitedPlace> _places = {};
  bool _loaded = false;

  VisitedStore({Future<String> Function()? pathProvider}) : _pathProvider = pathProvider;

  Set<String> get ids => Set.unmodifiable(_places.keys.toSet());
  int get count => _places.length;
  bool contains(String id) => _places.containsKey(id);

  bool isListened(String id) => _places[id]?.listened ?? false;
  bool isPassed(String id) => _places[id]?.passed ?? false;

  /// All places, most recent first.
  List<VisitedPlace> get places => _places.values.toList().reversed.toList();

  /// Narration heard to the end.
  List<VisitedPlace> get listenedPlaces => places.where((p) => p.listened).toList();

  /// Walked past but not listened to.
  List<VisitedPlace> get passedOnlyPlaces => places.where((p) => !p.listened).toList();

  Future<String> _path() async {
    if (_pathProvider != null) return _pathProvider();
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_fileName';
  }

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    if (kIsWeb && _pathProvider == null) return;
    try {
      final file = File(await _path());
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;
      // Oldest format: bare ids (no names). Their narration was started, so they count as both.
      if (data['visited'] is List) {
        for (final e in data['visited'] as List) {
          final id = e.toString();
          _places.putIfAbsent(id, () => VisitedPlace(id, '', 'other', passed: true, listened: true));
        }
      }
      if (data['places'] is List) {
        for (final e in data['places'] as List) {
          if (e is Map && e['id'] != null && e['name'] != null) {
            final id = e['id'].toString();
            _places.remove(id);
            _places[id] = VisitedPlace(
              id,
              e['name'].toString(),
              (e['kind'] ?? 'other').toString(),
              passed: e['passed'] as bool? ?? true,
              // Entries from earlier builds have no flag: narration had been started for them.
              listened: e['listened'] as bool? ?? true,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[VisitedStore] load failed: $e');
    }
  }

  /// The user walked past the place. Returns true when the place is new.
  Future<bool> markPassed(String id, {String? name, String kind = 'other'}) async {
    final old = _places[id];
    if (old == null) {
      _places[id] = VisitedPlace(id, name ?? '', kind, passed: true);
      await _save();
      return true;
    }
    if (old.passed) return false;
    _places[id] = old.copyWith(passed: true);
    await _save();
    return false;
  }

  /// Same as [markPassed] — kept for callers that do not care about the difference.
  Future<bool> add(String id, {String? name, String kind = 'other'}) =>
      markPassed(id, name: name, kind: kind);

  /// The narration of the place was played to the end.
  Future<void> markListened(String id, {String? name, String kind = 'other'}) async {
    final old = _places[id];
    if (old != null && old.listened) return;
    _places.remove(id); // moves to "most recent"
    _places[id] = (old ?? VisitedPlace(id, name ?? '', kind, passed: false)).copyWith(listened: true);
    await _save();
  }

  Future<void> clear() async {
    _places.clear();
    await _save();
  }

  Future<void> _save() async {
    if (kIsWeb && _pathProvider == null) return;
    try {
      final file = File(await _path());
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'places': [
            for (final p in _places.values)
              {'id': p.id, 'name': p.name, 'kind': p.kind, 'passed': p.passed, 'listened': p.listened},
          ],
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[VisitedStore] save failed: $e');
    }
  }
}
