/// The two UI languages ANT can display in. Independent of [ThemePreference]
/// and of the AI voice choice (`voiceId`) — a user could in principle read
/// English UI but want a Bangla-speaking assistant, though in practice most
/// will pick the same language for both.
enum AppLanguage {
  english,
  bangla;

  static AppLanguage fromFirestore(String? value) =>
      AppLanguage.values.firstWhere((v) => v.name == value, orElse: () => AppLanguage.english);

  /// BCP-47 locale for `flutter_tts` — see `TtsService.speak`.
  String get ttsLocale => this == AppLanguage.bangla ? 'bn-BD' : 'en-US';
}
