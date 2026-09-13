import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'log_redaction.dart';

/// The session log testers send back.
///
/// Recording starts at launch and never has to be switched on: a tester who
/// has to remember to start a log before the thing goes wrong will not have
/// one when it does. Every `debugPrint` in the app is already a deliberate
/// breadcrumb — 118 of them — so this keeps the last [capacity] of them in
/// memory and writes them out on request.
///
/// **Every line is redacted on the way in**, never on the way out. See
/// `log_redaction.dart`: a buffer holding raw text and cleaning it at export
/// is one bug away from shipping a blind user's speech, disability answers,
/// family phone numbers and location.
class DiagnosticsLog {
  DiagnosticsLog({this.capacity = 2000});

  /// Enough to cover a whole tester session's interesting part without
  /// letting a chatty loop push the beginning out within seconds. Roughly
  /// 200KB at these line lengths.
  final int capacity;

  final _lines = <String>[];
  DateTime? _startedAt;

  /// Set once installed, so a second call cannot chain the override onto
  /// itself and print every line twice.
  bool _installed = false;
  DebugPrintCallback? _previous;

  int get length => _lines.length;
  DateTime? get startedAt => _startedAt;

  /// Begins recording, and keeps the original `debugPrint` behaviour so a
  /// developer on a cable still sees everything in logcat.
  void install() {
    if (_installed) return;
    _installed = true;
    _startedAt = DateTime.now();
    _previous = debugPrint;
    final previous = _previous!;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) add(message);
      previous(message, wrapWidth: wrapWidth);
    };
  }

  @visibleForTesting
  void uninstall() {
    if (!_installed) return;
    debugPrint = _previous ?? debugPrintThrottled;
    _installed = false;
  }

  void add(String message) {
    final at = DateTime.now();
    final stamp = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}:'
        '${at.second.toString().padLeft(2, '0')}.'
        '${at.millisecond.toString().padLeft(3, '0')}';
    _lines.add('$stamp  ${redactLogLine(message)}');
    // Dropping from the front keeps the *end* of the session, which is where
    // whatever the tester is reporting actually happened.
    if (_lines.length > capacity) _lines.removeRange(0, _lines.length - capacity);
  }

  void clear() => _lines.clear();

  /// The whole report, header included.
  ///
  /// [header] carries build and device facts the tester should not have to
  /// recite — which build, which Android, which handset — since "the latest
  /// one" has already cost a round of confusion once.
  String render({Map<String, String> header = const {}}) {
    final buffer = StringBuffer()
      ..writeln('ANT diagnostics')
      ..writeln('session started: ${_startedAt?.toIso8601String() ?? 'unknown'}')
      ..writeln('written: ${DateTime.now().toIso8601String()}')
      ..writeln('lines: ${_lines.length}${_lines.length >= capacity ? ' (oldest dropped)' : ''}');
    header.forEach((k, v) => buffer.writeln('$k: $v'));
    buffer
      ..writeln()
      ..writeln('Transcripts, names, numbers, coordinates and account ids are')
      ..writeln('replaced with their shape before they reach this file.')
      ..writeln('-' * 60);
    for (final line in _lines) {
      buffer.writeln(line);
    }
    return buffer.toString();
  }

  /// Writes the report to a shareable file and returns its path.
  ///
  /// The temporary directory, not documents: this is something to hand to the
  /// share sheet and forget, not a file that should accumulate on the phone of
  /// someone who cannot see it to delete it.
  Future<File> writeReport({Map<String, String> header = const {}}) async {
    final dir = await getTemporaryDirectory();
    final at = DateTime.now();
    final name = 'ant-diagnostics-'
        '${at.year}${at.month.toString().padLeft(2, '0')}${at.day.toString().padLeft(2, '0')}-'
        '${at.hour.toString().padLeft(2, '0')}${at.minute.toString().padLeft(2, '0')}.txt';
    final file = File('${dir.path}/$name');
    await file.writeAsString(render(header: header));
    return file;
  }
}

/// One per app. Installed from `main` before anything else logs.
final diagnosticsLog = DiagnosticsLog();
