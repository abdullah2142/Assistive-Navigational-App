import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../services/tts_service.dart';

final ttsServiceProvider = Provider<TtsService>((ref) => TtsService());

/// Defaults to `true`: a fully blind user setting the app up with no
/// caretaker present needs spoken guidance starting from the very first
/// screen, before they've necessarily found or enabled their OS screen
/// reader. Every onboarding screen exposes a visible/announced toggle to
/// turn this off (see `OnboardingScaffold`) for anyone who doesn't want it.
final ttsEnabledProvider = StateProvider<bool>((ref) => true);
