import 'dart:typed_data';

/// Wraps raw PCM16 samples (what `record`'s `pcm16bits` stream encoder
/// produces) in a standard 44-byte WAV header so any player — including
/// `audioplayers`' `BytesSource` — can decode it directly. Used for Voice
/// Memos: streaming PCM avoids needing a real filesystem path, which native
/// file-based encoders require and which doesn't exist the same way on web.
Uint8List wrapPcm16AsWav(
  Uint8List pcmData, {
  required int sampleRate,
  required int numChannels,
}) {
  const bitsPerSample = 16;
  final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
  final blockAlign = numChannels * bitsPerSample ~/ 8;
  final dataLength = pcmData.length;

  final header = BytesBuilder();
  void writeString(String s) => header.add(s.codeUnits);
  void writeUint32(int v) => header.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void writeUint16(int v) => header.add([v & 0xFF, (v >> 8) & 0xFF]);

  writeString('RIFF');
  writeUint32(36 + dataLength);
  writeString('WAVE');
  writeString('fmt ');
  writeUint32(16); // fmt chunk size
  writeUint16(1); // PCM format
  writeUint16(numChannels);
  writeUint32(sampleRate);
  writeUint32(byteRate);
  writeUint16(blockAlign);
  writeUint16(bitsPerSample);
  writeString('data');
  writeUint32(dataLength);

  final builder = BytesBuilder();
  builder.add(header.toBytes());
  builder.add(pcmData);
  return builder.toBytes();
}
