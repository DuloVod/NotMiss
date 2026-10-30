import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';

/// Remembers which places the user has already been told about, across walks and restarts.
///
/// Keeps working in memory when the disk is unavailable (web, tests), so a storage problem
/// can never get in the way of a walk.
/// A place the user has been told about.
class VisitedPlace {
  final String id;
  final String name;

  /// [PoiKind] name, kept so the list can show the right icon without loading the place.
  final String kind;

  const VisitedPlace(this.id, this.name, this.kind);
}

class VisitedStore {
  static const _fileName = 'visited_pois.json';

  final Future<String> Function()? _pathProvider;
  final Set<String> _ids = {};
  final Map<String, VisitedPlace> _places = {};
  bool _loaded = false;

  VisitedStore({Future<String> Function()? pathProvider}) : _pathProvider = pathProvider;

  Set<String> get ids => Set.unmodifiable(_ids);
  int get count => _ids.length;
  bool contains(String id) => _ids.contains(id);

  /// Places with a known name, most recently visited first.
  List<VisitedPlace> get places => _places.values.toList().reversed.toList();

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
      if (data is Map && data['visited'] is List) {
        _ids.addAll((data['visited'] as List).map((e) => e.toString()));
      }
      if (data is Map && data['places'] is List) {
        for (final e in data['places'] as List) {
          if (e is Map && e['id'] != null && e['name'] != null) {
            final id = e['id'].toString();
            _ids.add(id);
            _places[id] = VisitedPlace(id, e['name'].toString(), (e['kind'] ?? 'other').toString());
          }
        }
      }
    } catch (e) {
      debugPrint('[VisitedStore] load failed: $e');
    }
  }

  /// Returns true when [id] was not known before.
  Future<bool> add(String id, {String? name, String kind = 'other'}) async {
    final isNew = _ids.add(id);
    final hasNewName = name != null && name.isNotEmpty && !_places.containsKey(id);
    if (hasNewName) _places[id] = VisitedPlace(id, name, kind);
    if (!isNew && !hasNewName) return false;
    await _save();
    return isNew;
  }

  Future<void> clear() async {
    _ids.clear();
    _places.clear();
    await _save();
  }

  Future<void> _save() async {
    if (kIsWeb && _pathProvider == null) return;
    try {
      final file = File(await _path());
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'visited': _ids.toList(),
        'places': [
          for (final p in _places.values) {'id': p.id, 'name': p.name, 'kind': p.kind},
        ],
      }), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[VisitedStore] save failed: $e');
    }
  }
}
