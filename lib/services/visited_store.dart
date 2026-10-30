import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';

/// Remembers which places the user has already been told about, across walks and restarts.
///
/// Keeps working in memory when the disk is unavailable (web, tests), so a storage problem
/// can never get in the way of a walk.
class VisitedStore {
  static const _fileName = 'visited_pois.json';

  final Future<String> Function()? _pathProvider;
  final Set<String> _ids = {};
  bool _loaded = false;

  VisitedStore({Future<String> Function()? pathProvider}) : _pathProvider = pathProvider;

  Set<String> get ids => Set.unmodifiable(_ids);
  int get count => _ids.length;
  bool contains(String id) => _ids.contains(id);

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
    } catch (e) {
      debugPrint('[VisitedStore] load failed: $e');
    }
  }

  /// Returns true when [id] was not known before.
  Future<bool> add(String id) async {
    if (!_ids.add(id)) return false;
    await _save();
    return true;
  }

  Future<void> clear() async {
    _ids.clear();
    await _save();
  }

  Future<void> _save() async {
    if (kIsWeb && _pathProvider == null) return;
    try {
      final file = File(await _path());
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({'visited': _ids.toList()}), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[VisitedStore] save failed: $e');
    }
  }
}
