/// Conditional export so nothing importing `WakeWordService` ever pulls in
/// `tflite_flutter` (an FFI plugin — `dart:ffi` isn't available on web at
/// all) when building for web. `dart.library.io` exists on
/// Android/iOS/desktop and not on web, which is exactly the split needed:
/// real on-device inference everywhere the app actually ships, an inert
/// stub on the web dev-testing target. See `wake_word_service_native.dart`
/// and `wake_word_service_stub.dart` — both define the same
/// `WakeWordService` public API, so callers never need to know which one
/// they got.
library;

export 'wake_word_service_stub.dart' if (dart.library.io) 'wake_word_service_native.dart';
