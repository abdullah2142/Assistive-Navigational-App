/// The text sizes this app offers, as a fixed ladder of named steps.
///
/// There used to be no ladder — the slider ran 0.8 to 2.0 in thirteen 0.1
/// stops and the voice command "make the text bigger" added 0.15. Those two
/// do not even land on the same values: a user who asked out loud got 1.15,
/// which the slider could not represent and which no label described. And
/// 0.1 between neighbouring stops is a change a low-vision user cannot see
/// they made, so the control answered a request with what looked like
/// nothing happening.
///
/// Five steps, each a clear jump from the last. A setting whose whole
/// audience is people who have trouble reading it should have few enough
/// options to say out loud, and every one of them should be obviously
/// different from its neighbours.
library;

import 'dart:math' as math;

/// The ladder, ascending. [normalScale] is the default.
const List<double> textScaleLevels = [0.8, 1.0, 1.25, 1.5, 2.0];

/// The default, and the value a fresh profile carries.
const double normalScale = 1.0;

/// Index of the level [scale] is on, snapping to the nearest rung.
///
/// Snapping rather than rejecting, because profiles written before the
/// ladder existed hold arbitrary values (1.15, 1.30) and must still map to
/// something the slider can show and the app can name.
int levelIndexFor(double scale) {
  var best = 0;
  var bestGap = double.infinity;
  for (var i = 0; i < textScaleLevels.length; i++) {
    final gap = (textScaleLevels[i] - scale).abs();
    if (gap < bestGap) {
      bestGap = gap;
      best = i;
    }
  }
  return best;
}

/// [scale] rounded onto the ladder.
double snapToLevel(double scale) => textScaleLevels[levelIndexFor(scale)];

/// One step bigger (or smaller, for a negative [steps]), clamped at the ends.
///
/// This is what "make the text bigger" resolves to. Stepping by *index*
/// rather than by a fixed 0.15 is what keeps the voice command and the
/// slider on the same values — and it means each spoken request produces a
/// visible change, including the last one, which used to add 0.15 to 1.95
/// and clamp back to a number the user could not tell from where they were.
double stepScale(double from, int steps) {
  final next = (levelIndexFor(from) + steps).clamp(0, textScaleLevels.length - 1);
  return textScaleLevels[next];
}

/// Smallest and largest, for clamping anything arriving from outside.
final double minTextScale = textScaleLevels.reduce(math.min);
final double maxTextScale = textScaleLevels.reduce(math.max);
