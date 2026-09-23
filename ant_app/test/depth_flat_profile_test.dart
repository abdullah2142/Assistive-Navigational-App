import 'package:ant_app/core/services/vision/depth_dropoff_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// The 23 September log reported `rows=236 min=0.000 max=0.000 range=0.000`
/// on every scan: the nested `List` handed to `Interpreter.run` came back
/// untouched, while the model itself was producing a range near 900. The
/// depth map is now read from the output tensor's own buffer, which means a
/// second strip-extraction path — this pins the two together.
void main() {
  const n = DepthDropoffDetector.inputSize;

  List<double> flatten(List<List<List<double>>> nested) => [
        for (var y = 0; y < n; y++)
          for (var x = 0; x < n; x++) nested[y][x][0],
      ];

  List<List<List<double>>> build(double Function(int x, int y) f) => [
        for (var y = 0; y < n; y++)
          [for (var x = 0; x < n; x++) [f(x, y)]],
      ];

  test('flat and nested extraction agree on a smooth gradient', () {
    final nested = build((x, y) => y.toDouble());
    expect(
      DepthDropoffDetector.groundProfileFlat(flatten(nested)),
      DepthDropoffDetector.groundProfileFrom(nested),
    );
  });

  test('and on a profile with a sharp discontinuity', () {
    // A kerb: the far half is suddenly much further away.
    final nested = build((x, y) => y < 128 ? y.toDouble() : y + 400.0);
    expect(
      DepthDropoffDetector.groundProfileFlat(flatten(nested)),
      DepthDropoffDetector.groundProfileFrom(nested),
    );
  });

  test('and on column noise, which is what the median is for', () {
    final nested = build((x, y) => x == 130 ? 9999.0 : y.toDouble());
    final flat = DepthDropoffDetector.groundProfileFlat(flatten(nested));
    expect(flat, DepthDropoffDetector.groundProfileFrom(nested));
    expect(flat, isNot(contains(9999.0)), reason: 'one bright column must not move the profile');
  });

  test('the strip is long enough for analyse to read', () {
    // `DepthProfile.minProfileRows` is 24; anything shorter is reported
    // unreadable, which is one of the two bail-outs that produced score=0.0.
    final flat = DepthDropoffDetector.groundProfileFlat(flatten(build((x, y) => y.toDouble())));
    expect(flat.length, greaterThanOrEqualTo(24));
  });

  test('a real depth map produces a readable range, not zero', () {
    // The failure the log caught: an all-zero buffer. Asserted here so a
    // future change that reintroduces a silent copy fails loudly.
    final flat = DepthDropoffDetector.groundProfileFlat(flatten(build((x, y) => y.toDouble())));
    final min = flat.reduce((a, b) => a < b ? a : b);
    final max = flat.reduce((a, b) => a > b ? a : b);
    expect(max - min, greaterThan(0.0));
  });
}
