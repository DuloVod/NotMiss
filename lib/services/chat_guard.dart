/// First line of defence for the AI chat: decides locally, without spending a model request.
/// The model has its own topic check on top (see AiService.answerQuestionAboutPoi).
class ChatGuard {
  ChatGuard._();

  static const int maxQuestionChars = 300;

  /// Attempts to make the model drop its rules or act as something other than a guide.
  static final _manipulation = RegExp(
    r'ignore (all |the |your )?(previous|above|prior)|system prompt|developer mode|jailbreak|'
    r'act as|pretend (to be|you)|you are now|'
    r'ігноруй|забудь (всі |усі |свої |попередні )?(інструкц|правил|вказівк)|'
    r'системн\S* (промпт|інструкц|повідомл)|твої (інструкц|правила)|свої (інструкц|правила)|'
    r'уяви,? що ти|прикинься|тепер ти\b|'
    r'игнорируй|забудь (все |свои )?(инструкц|правил)|системн\S* промпт',
    caseSensitive: false,
    unicode: true,
  );

  /// Requests that can never be about a place on the map.
  static final _offTopic = RegExp(
    r'напиши (код|програм|скрипт|есе|реферат|вірш|твір|лист)|write (code|a program|a script|an essay|a poem)|'
    r'\bpython\b|\bjavascript\b|\bsql\b|'
    r'рецепт|домашн\S* завдан|розв.?яжи|реши задач|solve (this|the)|'
    r'курс (долара|євро|валют|біткоїн)|прогноз погоди|гороскоп',
    caseSensitive: false,
    unicode: true,
  );

  static String refusal(String poiName) =>
      'Я відповідаю лише про «$poiName»: його історію, людей і події, пов\'язані з ним, '
      'архітектуру та відвідування. Запитайте, будь ласка, про це місце.';

  static String unknown(String poiName) =>
      'У перевірених джерелах про «$poiName» цього немає, тож не хочу вигадувати. '
      'Спробуйте запитати про його історію чи особливості.';

  static const String tooLong = 'Запитання задовге. Сформулюйте його коротше, до 300 символів.';

  static const String limitReached =
      'Про це місце вже поставлено багато запитань. Перейдемо до наступної точки маршруту?';

  /// Answer to give straight away, or null when the question may go to the model.
  static String? localAnswer(String question, String poiName) {
    final q = question.trim();
    if (q.length > maxQuestionChars) return tooLong;
    if (_manipulation.hasMatch(q) || _offTopic.hasMatch(q)) return refusal(poiName);
    return null;
  }

  /// The question is inserted into a prompt as data: it must not be able to close the wrapper.
  static String sanitize(String question) =>
      question.replaceAll(RegExp(r'[<>{}\[\]`]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
