import 'dart:math' as math;

/// How somebody might actually get somewhere in Dhaka.
enum CommuteMode { walk, rickshaw, cng, bus }

/// One way of making the trip, with what it is likely to cost in time.
class CommuteOption {
  const CommuteOption({
    required this.mode,
    required this.minutes,
    required this.isTrafficAware,
  });

  final CommuteMode mode;
  final int minutes;

  /// True when [minutes] came from a live traffic-aware duration rather than
  /// from the time-of-day model below.
  ///
  /// Said out loud, because the two deserve different confidence: "about
  /// twenty minutes" from live traffic is a figure to leave the house on,
  /// and the same number from an average is a guess worth hedging.
  final bool isTrafficAware;
}

/// Chooses the sensible ways to reach a destination, and how long each will
/// take.
///
/// ## Why walking distance was never the answer
///
/// Every estimate this app gave was route length over a fixed walking speed.
/// That is honest for a footpath and useless for deciding when to leave: a
/// 6km trip is ninety minutes on foot, twenty-five by CNG at eleven in the
/// morning, and an hour by CNG at six in the evening. Asked for as jam-based
/// ETA to help the user plan, and as narrating the transport options for a
/// destination — which turn out to be the same feature, because the option
/// and its cost are the same question.
///
/// ## Why this is arithmetic and not a model
///
/// The one number worth paying for is how long a *vehicle* takes right now,
/// which Routes API answers with a traffic-aware DRIVE duration. Everything
/// else here is a ratio applied to that: a cycle-rickshaw is slower than a
/// car and unaffected by the jams that stop one, a CNG auto-rickshaw moves
/// roughly at traffic speed and filters through some of it, and a bus is
/// traffic speed plus the time it spends stopped.
///
/// Those ratios are estimates and are labelled as such when spoken. Pretending
/// to a precision nobody has is worse than a hedged number: a blind user who
/// is told "twenty minutes" and arrives in forty has been given a reason to
/// stop trusting every other number this app says.
class CommutePlanner {
  const CommutePlanner();

  /// Below this, nothing but walking is worth suggesting.
  ///
  /// Hailing a rickshaw, agreeing a fare and getting in costs several
  /// minutes on its own, and for a short hop it is slower than walking as
  /// well as more expensive.
  static const double minRideMeters = 700;

  /// Above this, walking stops being an option worth naming for somebody
  /// navigating by cane through Dhaka traffic.
  static const double maxWalkMeters = 3000;

  /// Metres per second on foot — the same figure `RoutingService` uses, so
  /// the two cannot drift.
  static const double walkingSpeedMps = 1.3;

  /// A cycle-rickshaw's own pace, independent of motor traffic.
  ///
  /// It does not sit in the jam a car sits in — it filters, and on a bad
  /// evening it genuinely beats one. So this is a flat speed rather than a
  /// ratio of the driving time, which is the whole reason a rickshaw is
  /// worth suggesting at all.
  static const double rickshawSpeedMps = 3.3;

  /// A CNG auto-rickshaw relative to a car. Slightly faster than traffic,
  /// because it filters, but bound by the same roads.
  static const double cngTrafficRatio = 0.9;

  /// A bus relative to a car: traffic speed, plus stops.
  static const double busTrafficRatio = 1.5;

  /// Time added for finding and boarding a bus.
  static const int busOverheadMinutes = 10;

  /// Time added for hailing anything and agreeing a fare.
  static const int hailOverheadMinutes = 3;

  /// The options worth offering for a trip of [distanceMeters].
  ///
  /// [drivingMinutes] is a traffic-aware car duration when one could be
  /// fetched; null falls back to [_estimatedDrivingMinutes], which is the
  /// same arithmetic against a time-of-day speed rather than a live one.
  ///
  /// Ordered fastest first, because the question behind this is "when do I
  /// need to leave" and the fastest option is what answers it.
  List<CommuteOption> optionsFor({
    required double distanceMeters,
    int? drivingMinutes,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now();
    final trafficAware = drivingMinutes != null;
    final driving = drivingMinutes ?? _estimatedDrivingMinutes(distanceMeters, now);

    final options = <CommuteOption>[];

    if (distanceMeters <= maxWalkMeters) {
      options.add(CommuteOption(
        mode: CommuteMode.walk,
        minutes: _minutes(distanceMeters / walkingSpeedMps),
        // Walking is unaffected by traffic, so this figure is exact in a way
        // none of the others are.
        isTrafficAware: true,
      ));
    }

    if (distanceMeters >= minRideMeters) {
      options.add(CommuteOption(
        mode: CommuteMode.rickshaw,
        minutes: _minutes(distanceMeters / rickshawSpeedMps) + hailOverheadMinutes,
        isTrafficAware: false,
      ));
      options.add(CommuteOption(
        mode: CommuteMode.cng,
        minutes: math.max(1, (driving * cngTrafficRatio).round()) + hailOverheadMinutes,
        isTrafficAware: trafficAware,
      ));
      options.add(CommuteOption(
        mode: CommuteMode.bus,
        minutes: math.max(1, (driving * busTrafficRatio).round()) + busOverheadMinutes,
        isTrafficAware: trafficAware,
      ));
    }

    options.sort((a, b) => a.minutes.compareTo(b.minutes));
    return options;
  }

  /// A car's time when no live figure could be had.
  ///
  /// Dhaka's traffic is not a smooth curve — it is two long peaks with a
  /// tolerable middle — so this is a step function over the hour rather than
  /// an average, which would be wrong at both ends of the day.
  int _estimatedDrivingMinutes(double metres, DateTime now) =>
      _minutes(metres / _drivingSpeedMpsAt(now));

  /// Metres per second for a car, by hour of day.
  ///
  /// Dhaka's average traffic speed is widely reported around 4-5 km/h in the
  /// worst of the peaks and perhaps 20 km/h late at night. These are the
  /// bands, and they are estimates — which is why anything derived from them
  /// is marked `isTrafficAware: false` and hedged when spoken.
  static double _drivingSpeedMpsAt(DateTime now) {
    final hour = now.hour;
    // Morning peak, school and office run.
    if (hour >= 8 && hour < 11) return 1.7;
    // Evening peak, the worst of the day.
    if (hour >= 16 && hour < 21) return 1.5;
    // Overnight, genuinely quick.
    if (hour >= 23 || hour < 6) return 5.5;
    return 3.0;
  }

  static int _minutes(double seconds) => math.max(1, (seconds / 60).round());
}
