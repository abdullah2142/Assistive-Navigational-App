import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Weather, for deciding whether a walk is a good idea.
///
/// ## Why this is a safety feature and not a nicety
///
/// Dhaka rain does not make a walk unpleasant, it makes it unwalkable. A
/// footpath that was passable an hour ago becomes standing water of unknown
/// depth over an open drain, which for somebody navigating by cane is the
/// hazard this whole app exists to keep them away from. Heat is the other
/// half: 35°C with high humidity is a real risk to someone who cannot see a
/// shaded route and cannot quickly find somewhere to sit.
///
/// ## Open-Meteo
///
/// No key, no account, no billing — which is the whole reason it is here.
/// Every other cloud dependency in this app is a credential compiled into
/// the APK and metered against a free tier that has already run out once
/// (see `GroqAssistantService`). A forecast that cannot fail that way is
/// worth a small loss of precision.
///
/// Fails quiet and returns null. A missing forecast must never block a
/// route: the user asked to go somewhere, and "I could not check the
/// weather" is not a reason to refuse them.
class WeatherService {
  WeatherService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 6);

  /// How long a reading stays good.
  ///
  /// Weather does not change in ten minutes, and this is asked on every
  /// route request and every ambient check — an uncached version would be a
  /// network round trip on the path of somebody who just said they urgently
  /// need a toilet.
  static const Duration cacheLifetime = Duration(minutes: 10);

  _CachedWeather? _cached;

  /// Current conditions at [latitude]/[longitude], or null if unavailable.
  Future<WeatherReading?> current({
    required double latitude,
    required double longitude,
    DateTime Function()? now,
  }) async {
    final clock = now ?? DateTime.now;
    final cached = _cached;
    if (cached != null && clock().difference(cached.readAt) < cacheLifetime) {
      return cached.reading;
    }

    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': latitude.toStringAsFixed(4),
      'longitude': longitude.toStringAsFixed(4),
      'current': 'temperature_2m,apparent_temperature,precipitation,weather_code',
      // Rain in the next hour is what decides whether to set off now, which
      // is a different question from what it is doing this second.
      'hourly': 'precipitation_probability',
      'forecast_hours': '2',
      'timezone': 'auto',
    });

    try {
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) {
        debugPrint('[Weather] HTTP ${response.statusCode}');
        return null;
      }
      final reading = parse(response.body);
      if (reading != null) {
        _cached = _CachedWeather(reading, clock());
        debugPrint('[Weather] ${reading.temperatureC.round()}°C '
            '(feels ${reading.feelsLikeC.round()}°C) '
            'rain=${reading.precipitationMm}mm '
            'nextHour=${reading.rainChanceNextHourPercent}% '
            'code=${reading.code}');
      }
      return reading;
    } catch (e) {
      debugPrint('[Weather] lookup failed: $e');
      return null;
    }
  }

  /// Pure, so the shape of Open-Meteo's response is testable without a
  /// network — the same split `NavigationNarrator` has from its controller.
  @visibleForTesting
  static WeatherReading? parse(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return null;
      final current = json['current'];
      if (current is! Map<String, dynamic>) return null;

      double num2d(Object? v) => v is num ? v.toDouble() : 0;

      // The next hour's chance of rain, not this hour's — `forecast_hours: 2`
      // returns the current hour first.
      var rainChance = 0;
      final hourly = json['hourly'];
      if (hourly is Map<String, dynamic>) {
        final probabilities = hourly['precipitation_probability'];
        if (probabilities is List) {
          for (final p in probabilities) {
            if (p is num && p.toInt() > rainChance) rainChance = p.toInt();
          }
        }
      }

      return WeatherReading(
        temperatureC: num2d(current['temperature_2m']),
        feelsLikeC: num2d(current['apparent_temperature']),
        precipitationMm: num2d(current['precipitation']),
        rainChanceNextHourPercent: rainChance,
        code: current['weather_code'] is num ? (current['weather_code'] as num).toInt() : 0,
      );
    } catch (e) {
      debugPrint('[Weather] could not parse: $e');
      return null;
    }
  }
}

class _CachedWeather {
  const _CachedWeather(this.reading, this.readAt);
  final WeatherReading reading;
  final DateTime readAt;
}

/// What the weather is doing, reduced to the things that change a walk.
class WeatherReading {
  const WeatherReading({
    required this.temperatureC,
    required this.feelsLikeC,
    required this.precipitationMm,
    required this.rainChanceNextHourPercent,
    required this.code,
  });

  final double temperatureC;

  /// Humidity-adjusted. The one that matters in Dhaka, where 33°C at 85%
  /// humidity is harder work than 36°C dry.
  final double feelsLikeC;

  final double precipitationMm;
  final int rainChanceNextHourPercent;

  /// WMO weather code. 95+ is thunderstorm.
  final int code;

  /// Raining now, hard enough to matter on foot.
  bool get isRainingNow => precipitationMm >= rainNowMm;

  /// Likely to rain before they get there.
  bool get mayRainSoon => rainChanceNextHourPercent >= rainSoonPercent;

  bool get isThunderstorm => code >= 95;

  /// Hot enough to be a risk on a walk of any length.
  bool get isVeryHot => feelsLikeC >= hotFeelsLikeC;

  /// Whether this is worth saying out loud at all.
  ///
  /// The bar is deliberately high. An assistant that comments on the weather
  /// every time somebody asks for a route becomes one the user talks over,
  /// and the warning that matters then goes with it.
  bool get isWorthMentioning =>
      isRainingNow || mayRainSoon || isThunderstorm || isVeryHot;

  /// 0.2mm/h is drizzle you would notice; below that is not worth a sentence.
  static const double rainNowMm = 0.2;

  /// Under half, "it might rain" is noise — it might also not.
  static const int rainSoonPercent = 50;

  /// Bangladesh's own heat-warning threshold sits around here, and it is the
  /// apparent temperature that the body actually experiences.
  static const double hotFeelsLikeC = 36;
}
