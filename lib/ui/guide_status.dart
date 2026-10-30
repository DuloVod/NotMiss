/// How the guide's state is shown to the user: one calm line, never a log of internal steps.
enum GuideTone {
  /// Normal operation — nothing to show.
  calm,

  /// Working on it by itself (searching, preparing the story) — a quiet spinner.
  busy,

  /// The user can do something about it — shown together with an action button.
  attention,
}

class GuideStatus {
  final String text;
  final GuideTone tone;

  /// Label of the single button (e.g. «Повторити»); null when the user cannot help.
  final String? actionLabel;

  const GuideStatus(this.text, this.tone, {this.actionLabel});

  bool get hasAction => actionLabel != null;

  @override
  String toString() => 'GuideStatus($tone, $text, $actionLabel)';
}
