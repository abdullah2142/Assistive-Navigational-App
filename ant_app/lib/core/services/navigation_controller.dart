import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../localization/app_language.dart';
import '../localization/dashboard_strings.dart';
import 'navigation_narrator.dart';
import 'route_planning_service.dart';
import 'place_categories.dart';
import 'routing_service.dart' show ManeuverKind, RoutingService;
import 'haptics_service.dart';
import 'tts_service.dart';

// The named parameters below are deliberately not initializing formals:
// they are named for the caller ('store', 'tts') while the fields are
// private ('_store', '_tts'), which is the convention across this
// codebase and what makes the constructors readable at the call site.
// ignore_for_file: prefer_initializing_formals

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
  NavigationController({
    required TtsService tts,
    HapticsService? haptics,
    Stream<Position>? positionStream,
    RoutingService? routing,
  })  : _tts = tts,
        // Lazily defaulted for the same reason `_haptics` is: every existing
        // test builds this with a TTS alone, and a controller that cannot
        // look up bus stops still narrates every turn.
        _routing = routing ?? RoutingService(),
        // Defaulted rather than required: every existing test builds this with
        // a TTS alone, and a controller that cannot buzz is still a controller
        // that narrates.
        _haptics = haptics ?? HapticsService(),
        // Injectable so a test can walk a synthetic track past a route
        // without a device, the same way `NavigationNarrator` is tested.
        _injectedStream = positionStream;

  final TtsService _tts;
  final HapticsService _haptics;
  final RoutingService _routing;
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

  /// The live state of the walk, for anything that displays it.
  ///
  /// A `ValueListenable` rather than another stream because the map wants
  /// the *current* value the moment it builds, not the next change — a
  /// panel shown mid-route would otherwise sit blank until the next GPS
  /// fix, which on a slow walk is several seconds of showing nothing.
  ///
  /// Null while no route is being narrated.
  final ValueNotifier<NavigationProgress?> progress = ValueNotifier(null);

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

  /// [describeRoute] false when the caller has already said where this
  /// route goes and how far it is — see [Dashboard.navigateStartedBrief].
  Future<void> start(
    RouteChoice route, {
    required AppLanguage language,
    bool describeRoute = true,
  }) async {
    await stop(silent: true);
    _route = route;
    _language = language;
    final d = Dashboard.of(language);

    // Set before the first GPS fix, so a map opened the instant a route is
    // accepted shows the whole distance rather than nothing at all.
    progress.value = NavigationProgress(
      maneuver: route.steps.isEmpty ? ManeuverKind.straight : route.steps.first.maneuver,
      streetName: route.steps.isEmpty ? '' : route.steps.first.streetName,
      metersToManeuver: route.steps.isEmpty ? route.distanceMeters : route.steps.first.distanceMeters,
      metersRemaining: route.distanceMeters,
      isFinalStep: route.steps.length == 1,
    );

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

    _narrator = NavigationNarrator(
      steps: route.steps,
      routePoints: route.points,
      // Crossings the router already knows about. They are announced by the
      // turn bands too, but a crossing deserves a warning before the "in 200
      // metres" band that a turn gets — stepping into a Dhaka road is not
      // the same class of event as turning a corner.
      landmarks: [
        for (final step in route.steps)
          if (step.maneuver == ManeuverKind.crossing)
            Landmark(location: step.location, kind: LandmarkKind.crossing),
      ],
    );

    // Bus stops are looked up after the narrator exists and are folded in
    // when they arrive.
    //
    // Deliberately not awaited: this is an Overpass round trip, and a user
    // who has just asked to be taken somewhere should start walking now, not
    // when a volunteer API answers. A route whose stops never arrive is a
    // route without bus-stop announcements, which is exactly what it was
    // before this existed.
    unawaited(_loadBusStops(route));
    await _speak(describeRoute
        ? d.navigateStarted(
            destination: route.destinationLabel,
            totalMeters: route.distanceMeters,
          )
        : d.navigateStartedBrief);

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
    progress.value = null;
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
    final here = LatLng(position.latitude, position.longitude);
    final cue = narrator.update(here);
    // After `update`, so the display and the speech agree about which
    // manoeuvre is current — `update` is what retires a passed one.
    progress.value = narrator.progressAt(here);
    if (cue != null) _announce(cue);
  }

  Future<void> _announce(NavigationCue cue) async {
    final d = Dashboard.of(_language);
    final step = cue.step;

    switch (cue.kind) {
      case NavigationCueKind.turnAhead:
        _cue(turnCueFor(step!.maneuver));
        await _speak(d.navigateTurnAhead(
          kind: step.maneuver,
          meters: cue.distanceMeters,
          streetName: step.streetName,
        ));
      case NavigationCueKind.turnNow:
        // One pulse for left, two for right — see `HapticCue.turnLeft`.
        _cue(turnCueFor(step!.maneuver));
        await _speak(cue.isFinalStep
            ? d.navigateFinalTurn(kind: step.maneuver, streetName: step.streetName)
            : d.navigateTurnNow(kind: step.maneuver, streetName: step.streetName));
      case NavigationCueKind.offRoute:
        // Long buzz — the "something is wrong" pattern.
        _cue(HapticCue.hazard);
        await _speak(d.navigateOffRoute);
      // Information, not an instruction — so a single buzz and a short
      // sentence, never the hazard pattern. A bus stop the user is walking
      // past is worth knowing about and is not a reason to stop.
      case NavigationCueKind.landmarkAhead:
        final landmark = cue.landmark!;
        _cue(HapticCue.navigation);
        await _speak(switch (landmark.kind) {
          LandmarkKind.busStop => d.landmarkBusStop(landmark.name),
          LandmarkKind.crossing => d.landmarkCrossing,
        });

      case NavigationCueKind.arrived:
        // Double buzz — "confirmed". One call now: the pattern is the
        // service's, not two impacts and a sleep spelled out at the call site.
        _cue(HapticCue.confirmation);
        await _speak(d.navigateArrived);
        await stop(silent: true);
        // Set *after* `stop`, which clears it: arriving is a state the map
        // has to be able to show, and it is also the signal `ChatController`
        // uses to retire the route. A bare null is indistinguishable from
        // "no route was ever planned".
        progress.value = const NavigationProgress(arrived: true);
    }
  }

  /// Starts [cue] alongside the instruction it belongs to.
  ///
  /// Deliberately **not** awaited, and that is a correctness requirement
  /// rather than a preference. Awaiting `play()` was tried and is a real
  /// regression, caught by `navigation_controller_test`: with no vibration
  /// plugin behind the platform channel the future never completes, so
  /// `_announce` never reached `_speak` and every turn instruction was
  /// silently dropped. Bounding it with a timeout only trades that for
  /// serialising announcements behind the timeout. A cue must never be able
  /// to delay or prevent the thing it accompanies — the same rule the earcon
  /// in `ChatStreamPanel._beginListening` documents.
  ///
  /// ## On "the haptics are out of sync"
  ///
  /// What the 22 September report describes is real, and the half of it this
  /// class can fix is fixed: the buzz now **says which way** (one pulse
  /// left, two right — see `HapticCue.turnLeft`), where before every turn in
  /// either direction felt identical.
  ///
  /// The remaining gap is not an ordering bug. Both calls start in the same
  /// microtask; what separates them is that speech has a start-up cost the
  /// motor does not — engine warm-up on device, and a synthesis round trip
  /// on Cloud TTS — so the buzz lands first and the words follow a few
  /// hundred milliseconds later. Closing that needs a start-of-utterance
  /// signal from `TtsService`, which resolves on *completion* and has no
  /// "now speaking" callback to hang this on. Adding one is the fix; faking
  /// it with a fixed delay here would be guessing at a latency that varies
  /// between the cloud and on-device paths by an order of magnitude.
  void _cue(HapticCue cue) {
    unawaited(_haptics.play(cue).catchError((Object e) {
      debugPrint('[Navigation] haptic cue failed: $e');
    }));
  }

  /// Finds the bus stops along [route] and gives them to the narrator.
  ///
  /// Asked for as "should warn when bus stop or crossing or intersection is
  /// near". A crossing is a manoeuvre and arrives in the route geometry; a
  /// bus stop is neither, and appears nowhere in a walking route — so it has
  /// to be searched for.
  ///
  /// Searched around the route's midpoint with a radius that covers it,
  /// rather than once per step, because Overpass is a volunteer service and
  /// one query per journey is the polite amount. Stops that turn out to be
  /// far from the actual path simply never come within
  /// `NavigationNarrator.landmarkRadiusMeters` and are never announced.
  Future<void> _loadBusStops(RouteChoice route) async {
    if (route.points.isEmpty) return;
    final category = placeCategories.firstWhere((c) => c.id == 'bus_stop');
    final middle = route.points[route.points.length ~/ 2];
    // Half the route's length, plus slack, so one circle covers it.
    final radius = (route.distanceMeters / 2 + 300).clamp(300.0, 3000.0);
    try {
      final stops = await _routing.nearbyOfCategory(
        origin: middle,
        category: category,
        radiusMeters: radius,
      );
      final narrator = _narrator;
      // The journey may have ended while this was in flight.
      if (narrator == null || _route != route) return;
      narrator.addLandmarks([
        for (final stop in stops)
          Landmark(location: stop.location, kind: LandmarkKind.busStop, name: stop.name),
      ]);
      debugPrint('[Navigation] ${stops.length} bus stops along the route');
    } catch (e) {
      debugPrint('[Navigation] bus stop lookup failed: $e');
    }
  }

  Future<void> _speak(String text) async {
    _cues.add(text);
    await _tts.speak(text, language: _language);
  }

  void dispose() {
    _subscription?.cancel();
    _cues.close();
    progress.dispose();
  }
}
