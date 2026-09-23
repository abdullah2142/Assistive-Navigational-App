import 'package:ant_app/core/services/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backlog item 2. Open-Meteo, chosen because it needs no key and no
/// account — every other cloud dependency here is a credential metered
/// against a free tier that has already run out once.
void main() {
  String body({
    double temp = 30,
    double feels = 32,
    double precip = 0,
    List<int> chances = const [0, 0],
    int code = 0,
  }) =>
      '{"current":{"temperature_2m":$temp,"apparent_temperature":$feels,'
      '"precipitation":$precip,"weather_code":$code},'
      '"hourly":{"precipitation_probability":$chances}}';

  group('parsing Open-Meteo', () {
    test('reads the fields a walk depends on', () {
      final r = WeatherService.parse(body(temp: 31.4, feels: 38.2, precip: 1.5, code: 61))!;
      expect(r.temperatureC, closeTo(31.4, 0.01));
      expect(r.feelsLikeC, closeTo(38.2, 0.01));
      expect(r.precipitationMm, closeTo(1.5, 0.01));
      expect(r.code, 61);
    });

    test('takes the highest chance across the forecast window', () {
      // `forecast_hours: 2` returns this hour first; the question is whether
      // it rains before they arrive, not whether it is raining now.
      expect(WeatherService.parse(body(chances: [10, 80]))!.rainChanceNextHourPercent, 80);
    });

    test('malformed or empty responses are null, never a wrong reading', () {
      // Failing quiet is the contract: a missing forecast must never block a
      // route, and a *wrong* one is worse than none.
      expect(WeatherService.parse('not json'), isNull);
      expect(WeatherService.parse('{}'), isNull);
      expect(WeatherService.parse('[]'), isNull);
      expect(WeatherService.parse('{"current":null}'), isNull);
    });

    test('missing fields degrade to zero rather than throwing', () {
      final r = WeatherService.parse('{"current":{"temperature_2m":29}}')!;
      expect(r.temperatureC, 29);
      expect(r.precipitationMm, 0);
      expect(r.rainChanceNextHourPercent, 0);
    });
  });

  group('what is worth saying out loud', () {
    test('a fine day says nothing', () {
      // The bar is high on purpose. An assistant that remarks on the weather
      // before every route is one the user talks over.
      expect(WeatherService.parse(body(temp: 28, feels: 30))!.isWorthMentioning, isFalse);
    });

    test('rain now does', () {
      final r = WeatherService.parse(body(precip: 1.2))!;
      expect(r.isRainingNow, isTrue);
      expect(r.isWorthMentioning, isTrue);
    });

    test('a trace of drizzle does not', () {
      expect(WeatherService.parse(body(precip: 0.05))!.isRainingNow, isFalse);
    });

    test('a coin-flip chance of rain does not, a likely one does', () {
      expect(WeatherService.parse(body(chances: [0, 40]))!.mayRainSoon, isFalse);
      expect(WeatherService.parse(body(chances: [0, 70]))!.mayRainSoon, isTrue);
    });

    test('heat is judged on what the body feels, not the thermometer', () {
      // 33C at high humidity is harder work than 36C dry, and Dhaka is
      // humid — so the apparent temperature is the one that decides.
      expect(WeatherService.parse(body(temp: 40, feels: 34))!.isVeryHot, isFalse);
      expect(WeatherService.parse(body(temp: 33, feels: 39))!.isVeryHot, isTrue);
    });

    test('a thunderstorm is always worth saying', () {
      final r = WeatherService.parse(body(code: 95))!;
      expect(r.isThunderstorm, isTrue);
      expect(r.isWorthMentioning, isTrue);
    });
  });
}
