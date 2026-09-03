/// Conditional export so nothing importing `CloudSttService` ever pulls in
/// `grpc`'s `dart:io`-dependent transport when building for web. Same
/// pattern as `wake_word_service.dart` — see its doc comment.
library;

export 'cloud_stt_service_stub.dart' if (dart.library.io) 'cloud_stt_service_native.dart';
