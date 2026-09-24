/// Voice commands that end a user-side caretaker memo.
enum VoiceMemoCommand { send, cancel }

/// Recognizes only short, direct controls so ordinary message content is not
/// mistaken for an instruction.
VoiceMemoCommand? voiceMemoCommand(String transcript) {
  final normalized = transcript
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-zঀ-৿ ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  const sendPhrases = {
    'send',
    'send it',
    'send now',
    'send it now',
    'stop',
    'stop recording',
    'stop now',
    'পাঠাও',
    'পাঠিয়ে দাও',
    'থামাও',
  };
  const cancelPhrases = {
    'cancel',
    'cancel it',
    'cancel recording',
    'cancel that',
    'বাতিল',
    'বাতিল করো',
    'বাদ দাও',
  };
  if (cancelPhrases.contains(normalized)) return VoiceMemoCommand.cancel;
  if (sendPhrases.contains(normalized)) return VoiceMemoCommand.send;
  return null;
}
