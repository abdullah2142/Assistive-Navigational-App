import 'dart:typed_data';

/// The slice of `record`'s `AudioRecorder` that [WakeWordService] actually
/// uses.
///
/// Exists so the wake-word service's start/stop/suspend state machine can be
/// driven from a test. That machine is where the two hardest bugs in this
/// feature lived — a `start()` landing inside a suspension and stealing the
/// microphone from the speech recognizer, and a resume that never happened
/// because the suspension was taken a fraction of a second too early — and
/// neither is reachable without being able to make the recorder take a
/// controllable amount of time to come up.
///
/// Deliberately not the whole `AudioRecorder` surface: everything here is
/// something the wake word needs, and nothing here is a `record` type, so a
/// fake is four short methods rather than a mock of a plugin.
abstract class WakeWordAudioSource {
  /// Whether the OS has granted microphone access.
  Future<bool> hasPermission();

  /// Opens a 16 kHz mono PCM-16 capture stream.
  Future<Stream<Uint8List>> startStream();

  /// Closes the capture stream. Safe to call when nothing is open.
  Future<void> stop();

  /// Releases the underlying recorder for good.
  Future<void> dispose();
}
