import 'dart:ui' show Rect;
import 'package:share_plus/share_plus.dart';
import '../l10n/app_lang.dart';
import '../models/enriched_poi.dart';
import '../models/poi.dart';

/// Why a user says the information about a place is wrong.
enum ReportReason {
  wrongFacts('wrong facts', 'Неправильні факти', 'Wrong facts'),
  wrongPlace('story is about another place', 'Розповідь про інше місце', 'The story is about another place'),
  poorVoice('voice or language problem', 'Погано звучить або мова', 'Voice or language problem'),
  missing('place is wrong or does not exist', 'Такого місця немає або воно не там', 'The place is wrong or not there'),
  other('other', 'Інше', 'Other');

  final String code;
  final String uk;
  final String en;

  const ReportReason(this.code, this.uk, this.en);

  String get label => L.t(uk, en);
}

/// Sends a [text] somewhere (the system share sheet: mail, a messenger, notes).
typedef ReportSender = Future<void> Function(String subject, String text, Rect? origin);

/// "Inaccurate information" reports: everything a developer needs to understand and fix the
/// case is in one message, written in English whatever the app's language is.
class ReportService {
  ReportService({ReportSender? sender}) : _sender = sender ?? _share;

  final ReportSender _sender;

  static const String subject = 'NotMiss: inaccurate information';

  static Future<void> _share(String subject, String text, Rect? origin) async {
    await SharePlus.instance.share(ShareParams(text: text, subject: subject, sharePositionOrigin: origin));
  }

  /// The message. Nothing about the person is included: only the place and what the app said.
  static String compose({
    required Poi poi,
    EnrichedPoi? enriched,
    required ReportReason reason,
    String comment = '',
    required AppLang lang,
  }) {
    final b = StringBuffer()
      ..writeln('NotMiss — report: inaccurate information')
      ..writeln()
      ..writeln('Reason: ${reason.code}');
    final note = comment.trim();
    if (note.isNotEmpty) b.writeln('Comment: $note');
    b
      ..writeln()
      ..writeln('Place: ${poi.name}')
      ..writeln('Id: ${poi.id}')
      ..writeln('Coordinates: ${poi.latitude.toStringAsFixed(5)}, ${poi.longitude.toStringAsFixed(5)}')
      ..writeln('Language: ${lang.code}');
    final tags = poi.osmTags;
    if (tags != null && tags.isNotEmpty) {
      b.writeln('Map tags: ${tags.entries.take(12).map((e) => '${e.key}=${e.value}').join(', ')}');
    }
    if (enriched != null) {
      b
        ..writeln('Research status: ${enriched.researchStatus.name}')
        ..writeln('Content language: ${enriched.contentLang}');
      if (enriched.shortDescription?.isNotEmpty == true) {
        b.writeln('\nDescription shown:\n${enriched.shortDescription}');
      }
      if (enriched.narrationText?.isNotEmpty == true) {
        b.writeln('\nStory told:\n${enriched.narrationText}');
      }
      if (enriched.keyFacts.isNotEmpty) {
        b.writeln('\nFacts shown:');
        for (final f in enriched.keyFacts) {
          b.writeln('- ${f.fact}');
        }
      }
      if (enriched.sources.isNotEmpty) {
        b.writeln('\nSources used:');
        for (final s in enriched.sources) {
          b.writeln('- ${s.type}: ${s.title} ${s.url}'.trimRight());
        }
      }
    } else if (poi.narrationText.isNotEmpty) {
      b.writeln('\nStory told:\n${poi.narrationText}');
    }
    return b.toString().trimRight();
  }

  Future<void> send(String text, {Rect? origin}) => _sender(subject, text, origin);
}
