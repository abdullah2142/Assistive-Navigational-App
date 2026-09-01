/// Stand-in for real AI summarization (Gemini, via Module 3's function-calling
/// plumbing) — condenses a raw, possibly rambling piece of typed or dictated
/// text into one clean sentence. Purely local string manipulation for now;
/// swapping this one function for a Gemini call is the entire integration
/// point later modules need. Shared by the Crowdsource Hub's "Something
/// else" free-text report and the onboarding Passerby Messages screen's
/// "write your own" field — anywhere a person free-forms a thought that
/// then needs to stay short enough to read at a glance (or, for the
/// Passerby Helper, to fit legibly on a full screen).
String summarizeText(String raw) {
  final cleaned = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (cleaned.isEmpty) return cleaned;
  const maxLength = 140;
  var summary = cleaned.length <= maxLength ? cleaned : cleaned.substring(0, maxLength);
  if (cleaned.length > maxLength) {
    final lastSpace = summary.lastIndexOf(' ');
    if (lastSpace > 40) summary = summary.substring(0, lastSpace);
    summary = '$summary…';
  }
  return summary[0].toUpperCase() + summary.substring(1);
}
