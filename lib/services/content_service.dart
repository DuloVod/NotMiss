import '../models/poi.dart';

/// Provides narration content for a POI.
///
/// This is the seam between static narration and AI-generated narration.
/// In M3, it returns [poi.narrationText] directly.
/// In M4, [AiService] will override this with generated text.
class ContentService {
  /// Returns the narration text for [poi].
  ///
  /// If [aiText] is supplied (by AiService), it is used instead of the static text.
  String getNarration(Poi poi, {String? aiText}) {
    return aiText ?? poi.narrationText;
  }

  /// Builds the prompt string to send to the AI for generating narration.
  String buildAiPrompt(Poi poi) {
    final factsList = poi.facts.map((f) => '- $f').join('\n');
    return '''
You are an engaging audio guide for a walking tour.

Location: ${poi.name}

Facts about this place:
$factsList

Task:
Write a 30–60 second spoken narration about this location.
Rules:
- Use only the facts provided above. Do NOT invent additional historical details.
- Write in second person ("You are standing...") to make it immersive.
- Keep it conversational — this will be read aloud, not read silently.
- Use short sentences. Vary the rhythm.
- End with something thought-provoking or memorable.
- Do NOT use markdown, bullet points, or formatting.
- Output ONLY the narration text, nothing else.
''';
  }
}
