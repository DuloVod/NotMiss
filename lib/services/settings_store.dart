import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';
import '../l10n/app_lang.dart';
import 'analytics_service.dart';

/// The user's choices that survive a restart (for now: the language).
///
/// Works in memory when the disk is unavailable (web, tests): a storage problem must never
/// get in the way of a walk.
class SettingsStore {
  static const _fileName = 'settings.json';

  final Future<String> Function()? _pathProvider;
  AppLang? _lang;
  final Set<String> _reported = {};
  bool _loaded = false;
  String? _analyticsId;
  bool _analyticsEnabled = true;

  SettingsStore({Future<String> Function()? pathProvider}) : _pathProvider = pathProvider;

  /// The language the user picked, or null while they have not (the phone's language is used).
  AppLang? get lang => _lang;

  /// Random anonymous id of this installation (created on first use, never the phone's
  /// advertising id). Statistics are grouped by it.
  String get analyticsId => _analyticsId ??= AnalyticsService.newId();

  /// Whether anonymous usage statistics are sent (on by default; the user can switch it off).
  bool get analyticsEnabled => _analyticsEnabled;

  /// Creates and stores the id on the very first launch (so it survives a restart).
  Future<void> ensureAnalyticsId() async {
    if (_analyticsId != null) return;
    _analyticsId = AnalyticsService.newId();
    await _save();
  }

  Future<void> setAnalyticsEnabled(bool value) async {
    _analyticsEnabled = value;
    await _save();
  }

  /// Places the user has already reported (the report icon shows it).
  Set<String> get reported => Set.unmodifiable(_reported);

  Future<void> markReported(String poiId) async {
    if (!_reported.add(poiId)) return;
    await _save();
  }

  Future<String> _path() async {
    if (_pathProvider != null) return _pathProvider();
    final dir = await getApplicationSupportDirectory();
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
      if (data is Map) {
        _lang = AppLang.fromCode(data['lang'] as String?);
        final id = data['analyticsId'];
        if (id is String && id.isNotEmpty) _analyticsId = id;
        if (data['analyticsEnabled'] is bool) _analyticsEnabled = data['analyticsEnabled'] as bool;
        if (data['reported'] is List) {
          _reported.addAll((data['reported'] as List).map((e) => e.toString()));
        }
      }
    } catch (e) {
      debugPrint('[SettingsStore] load failed: $e');
    }
  }

  Future<void> setLang(AppLang lang) async {
    _lang = lang;
    await _save();
  }

  Future<void> _save() async {
    if (kIsWeb && _pathProvider == null) return;
    try {
      final file = File(await _path());
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'lang': _lang?.code,
          'reported': _reported.toList(),
          'analyticsId': _analyticsId,
          'analyticsEnabled': _analyticsEnabled,
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[SettingsStore] save failed: $e');
    }
  }
}
