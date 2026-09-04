import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../localization/app_language.dart';
import '../localization/dashboard_strings.dart';
import 'navigation_narrator.dart';
import 'route_planning_service.dart';
import 'tts_service.dart';

/// Drives spoken turn-by-turn navigation: subscribes to GPS, asks
/// [NavigationNarrator] what to say, and says it.
///
/// The split is deliberate — every decision about *what* to announce and
/// *when* lives in the narrator, which is a pure function of position and
/// route and is tested by walking synthetic tracks. This class only owns
/// the things that cannot be tested that way: the location stream, the
/// text-to-speech engine, and the vibration motor.
///
/// ## Haptics
///
/// Uses the three patterns `07_module_plan_haptics.md` allows, and no
/// others: a single buzz for a turn, a long buzz for a hazard or going off
/// route, a double buzz for arrival. Restricting the vocabulary is the
/// point — a blind user learns three patterns and knows them instantly,
/// where six become noise nobody can tell apart while walking.
class NavigationController {
  NavigationController({required TtsService tts, Stream<Position>? positionStream})
      : _tts = tts,
        // Injectable so a test can walk a synthetic track past a route
        // without a device, the same way `NavigationNarrator` is tested.
        _injectedStream = positionStream;

  final TtsService _tts;
  final Stream<Position>? _injectedStream;

  StreamSubscription<Position>? _subscription;
  NavigationNarrator? _narrator;
  RouteChoice? _route;
  AppLanguage _language = AppLanguage.english;

  bool get isNavigating => _narrator != null;
  RouteChoice? get activeRoute => _route;

  /// Emits every spoken cue, so the chat transcript can show the same
  /// directions it just said aloud. A Deaf-blind user, or one who has
  /// muted the voice, still needs them.
  final _cues = StreamController<String>.broadcast();
  Stream<String> get spokenCues => _cues.stream;

  /// Only report a fix that has actually moved, and only when it is
  /// accurate enough to act on.
  ///
  /// A stationary phone emits a constant trickle of jittering fixes, and
  /// feeding those to the narrator burns battery re-deciding the same
  /// thing several times a second. 5 m matches the granularity the
  /// narrator's own bands work at.
  static const int _minMovementMeters = 5;

  /// Fixes worse than this are dropped rather than acted on. A 100 m
  /// accuracy reading (indoors, under a flyover, in a dense alley) would
  /// otherwise look exactly like the user having wandered off route, and
  /// announcing that is worse than staying quiet for a few seconds.
  static const double _maxAcceptableAccuracyMeters = 50;

  Future<void> start(RouteChoice route, {required AppLanguage language}) async {
    await stop(silent: true);
    _route = route;
    _language = language;
    final d = Dashboard.of(language);

    if (route.steps.isEmpty) {
      // A route with no manoeuvres is still a usable route — the map arrow
      // and distance work — it just cannot be narrated turn by turn. Say so
      // rather than starting a navigation session that will never speak
      // again, which reads as the app having crashed.
      await _speak(d.navigateNoStepsFallback(
        destination: route.destinationLabel,
        meters: route.distanceMeters,
      ));
      return;
    }

    _narrator = NavigationNarrator(steps: route.steps, routePoints: route.points);
    await _speak(d.navigateStarted(
      destination: route.destinationLabel,
      totalMeters: route.distanceMeters,
    ));

    final stream = _injectedStream ??
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: _minMovementMeters,
          ),
        );
    _subscription = stream.listen(_onPosition, onError: (Object e) {
      debugPrint('[Navigation] position stream error: $e');
    });
  }

  Future<void> stop({bool silent = false}) async {
    await _subscription?.cancel();
    _subscription = null;
    final wasNavigating = _narrator != null;
    _narrator = null;
    _route = null;
    if (wasNavigating && !silent) {
      await _speak(Dashboard.of(_language).navigateStopped);
    }
  }

  void _onPosition(Position position) {
    final narrator = _narrator;
    if (narrator == null) return;
    if (position.accuracy > _maxAcceptableAccuracyMeters) {
      debugPrint('[Navigation] dropped a ${position.accuracy.round()}m fix as too imprecise');
      return;
    }
    final cue = narrator.update(LatLng(position.latitude, position.longitude));
    if (cue != null) _announce(cue);
  }

  Future<void> _announce(NavigationCue cue) async {
    final d = Dashboard.of(_language);
    final step = cue.step;

    switch (cue.kind) {
      case NavigationCueKind.turnAhead:
        HapticFeedback.selectionClick();
        await _speak(d.navigateTurnAhead(
          kind: step!.maneuver,
          meters: cue.distanceMeters,
          streetName: step.streetName,
        ));
      case NavigationCueKind.turnNow:
        // Single buzz — "turn", per the haptics module plan.
        HapticFeedback.mediumImpact();
        await _speak(cue.isFinalStep
            ? d.navigateFinalTurn(kind: step!.maneuver, streetName: step.streetName)
            : d.navigateTurnNow(kind: step!.maneuver, streetName: step.streetName));
      case NavigationCueKind.offRoute:
        // Long buzz — the "something is wrong" pattern.
        HapticFeedback.heavyImpact();
        await _speak(d.navigateOffRoute);
      case NavigationCueKind.arrived:
        // Double buzz — "confirmed".
        HapticFeedback.mediumImpact();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        HapticFeedback.mediumImpact();
        await _speak(d.navigateArrived);
        await stop(silent: true);
    }
  }

  Future<void> _speak(String text) async {
    _cues.add(text);
    await _tts.speak(text, language: _language);
  }

  void dispose() {
    _subscription?.cancel();
    _cues.close();
  }
}
