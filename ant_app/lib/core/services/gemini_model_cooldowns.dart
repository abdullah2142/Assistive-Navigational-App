import 'dart:async';

/// Process-wide cooldowns keyed by provider and model.
///
/// Google reports quotas by project and model. These timers do not distinguish
/// API keys within the same project. Once a model is cooling down, every
/// feature using that model skips it. Ordered chains retry their primary once
/// its timer expires.
class GeminiModelCooldowns {
  GeminiModelCooldowns({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<String, DateTime> _until = {};
  final Map<String, Timer> _timers = {};

  static final GeminiModelCooldowns shared = GeminiModelCooldowns();

  DateTime? resetAt(String model) {
    final until = _until[model];
    if (until != null && !until.isAfter(_now())) {
      _until.remove(model);
      _timers.remove(model)?.cancel();
      return null;
    }
    return until;
  }

  bool isCooling(String model) => resetAt(model) != null;

  /// Records a provider failure when its message identifies a quota or an
  /// overload. Returns the reset time, or null for ordinary failures.
  DateTime? recordFailure(String model, Object error) {
    final message = error.toString().toLowerCase();
    Duration? delay;
    if (message.contains('429') ||
        message.contains('resource_exhausted') ||
        message.contains('rate_limit') ||
        message.contains('rate limit') ||
        message.contains('quota')) {
      delay =
          _retryDelay(message) ??
          (message.contains('perday') ||
                  message.contains('per day') ||
                  message.contains('per_day') ||
                  message.contains('rpd')
              ? _untilPacificMidnight()
              : const Duration(minutes: 1));
    } else if (message.contains('503') ||
        message.contains('high demand') ||
        message.contains('unavailable') ||
        message.contains('timeout')) {
      delay = const Duration(seconds: 30);
    }
    if (delay == null) return null;
    return _start(model, delay);
  }

  DateTime recordReset(String model, Duration delay) => _start(model, delay);

  DateTime _start(String model, Duration delay) {
    final until = _now().add(delay);
    _until[model] = until;
    _timers.remove(model)?.cancel();
    _timers[model] = Timer(delay, () {
      if (_until[model] == until) _until.remove(model);
      _timers.remove(model);
    });
    return until;
  }

  static Duration? _retryDelay(String message) {
    final match = RegExp(
      r'(?:(?:try\s+again\s+in)|(?:retry(?:\s+in)?)|(?:retrydelay["\s:=]+))(?:\s*[:=]?\s*)(\d+(?:\.\d+)?)\s*s',
    ).firstMatch(message);
    if (match == null) return null;
    final seconds = double.tryParse(match.group(1)!);
    if (seconds == null || seconds <= 0) return null;
    return Duration(milliseconds: (seconds * 1000).ceil() + 1000);
  }

  /// Parses the relative duration formats used in Retry-After and
  /// x-ratelimit-reset-* response headers (for example `12.4s` or `90`).
  static Duration? parseRetryHeader(String? value) {
    if (value == null) return null;
    final text = value.trim().toLowerCase();
    final seconds = double.tryParse(text.replaceFirst(RegExp(r's$'), ''));
    if (seconds != null && seconds > 0) {
      return Duration(milliseconds: (seconds * 1000).ceil() + 1000);
    }
    final match = RegExp(r'(?:(\d+(?:\.\d+)?)m)?\s*(?:(\d+(?:\.\d+)?)s)?')
        .firstMatch(text);
    if (match == null || (match.group(1) == null && match.group(2) == null)) {
      return null;
    }
    final minutes = double.tryParse(match.group(1) ?? '0') ?? 0;
    final remainingSeconds = double.tryParse(match.group(2) ?? '0') ?? 0;
    final totalSeconds = minutes * 60 + remainingSeconds;
    if (totalSeconds <= 0) return null;
    return Duration(milliseconds: (totalSeconds * 1000).ceil() + 1000);
  }

  /// Gemini daily request quotas reset at midnight Pacific time. Convert the
  /// next Pacific midnight to UTC using the US daylight-saving calendar.
  Duration _untilPacificMidnight() {
    final utcNow = _now().toUtc();
    final offset = _isPacificDaylightTime(utcNow) ? -7 : -8;
    final pacificNow = utcNow.add(Duration(hours: offset));
    final nextMidnightPacific = DateTime.utc(
      pacificNow.year,
      pacificNow.month,
      pacificNow.day + 1,
    );
    final resetUtc = nextMidnightPacific.subtract(Duration(hours: offset));
    return resetUtc.difference(utcNow) + const Duration(minutes: 1);
  }

  static bool _isPacificDaylightTime(DateTime utc) {
    // DST starts on the second Sunday in March at 02:00 local (10:00 UTC)
    // and ends on the first Sunday in November at 02:00 local (09:00 UTC).
    final marchFirst = DateTime.utc(utc.year, 3, 1);
    final secondSunday = 1 + ((7 - marchFirst.weekday) % 7) + 7;
    final novemberFirst = DateTime.utc(utc.year, 11, 1);
    final firstSundayNovember = 1 + ((7 - novemberFirst.weekday) % 7);
    final starts = DateTime.utc(utc.year, 3, secondSunday, 10);
    final ends = DateTime.utc(utc.year, 11, firstSundayNovember, 9);
    return !utc.isBefore(starts) && utc.isBefore(ends);
  }
}
