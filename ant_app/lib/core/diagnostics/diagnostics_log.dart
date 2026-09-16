import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config/diagnostics_config.dart';
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
///
/// **It also appends to disk** (item 53). The in-memory buffer alone died with
/// the app, which is how round 3 lost most of what it learned: a tester hits a
/// bug, force-closes the app because it is stuck, and the evidence for what
/// they are about to report goes with it. So every line is also written to a
/// file, and the previous run's file is kept alongside this one — the report
/// carries both. Note the tension with item 26: the app is *supposed* to be
/// killable without loss, and this is the one place where being killable was
/// costing us the thing we needed most.
class DiagnosticsLog {
  DiagnosticsLog({this.capacity = 2000, this.maxSessionBytes = 512 * 1024});

  /// Enough to cover a whole tester session's interesting part without
  /// letting a chatty loop push the beginning out within seconds. Roughly
  /// 200KB at these line lengths.
  final int capacity;

  /// When the session file passes this, it is rotated into the previous slot
  /// and a fresh one is started. A session that runs for hours therefore keeps
  /// its most recent chunk on disk rather than either growing without bound on
  /// a tester's phone or being truncated at the end — which is the end we want.
  final int maxSessionBytes;

  static const String currentFileName = 'ant-session-current.log';
  static const String previousFileName = 'ant-session-previous.log';

  final _lines = <String>[];
  DateTime? _startedAt;

  /// Set once installed, so a second call cannot chain the override onto
  /// itself and print every line twice.
  bool _installed = false;
  DebugPrintCallback? _previous;

  // ---- disk ----------------------------------------------------------------
  Directory? _dir;
  IOSink? _sink;
  int _sessionBytes = 0;

  /// Lines recorded but not yet handed to the sink. This is the *only* queue:
  /// `add` always appends here, and attaching drains it. Lines logged while
  /// `attachToDirectory` is still awaiting the filesystem therefore land
  /// exactly once, which a separate "replay the buffer" step could not promise.
  final _pending = <String>[];
  bool _flushScheduled = false;
  Future<void> _writing = Future<void>.value();

  /// Kept rather than thrown: a log that cannot open its file must still
  /// record in memory and must never take the app down with it. Surfaced in
  /// the report so a silent failure cannot look like a quiet session.
  Object? _fileError;

  int _recoveredLines = 0;

  int get length => _lines.length;
  DateTime? get startedAt => _startedAt;

  /// Whether lines are actually reaching disk.
  bool get isPersisting => _sink != null;

  /// How many lines were recovered from the run before this one. Zero on a
  /// first launch, and what the settings tile reports so a tester can see that
  /// the session they force-closed was not lost.
  int get recoveredLines => _recoveredLines;

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
    final line = '$stamp  ${redactLogLine(message)}';
    _lines.add(line);
    // Dropping from the front keeps the *end* of the session, which is where
    // whatever the tester is reporting actually happened.
    if (_lines.length > capacity) _lines.removeRange(0, _lines.length - capacity);

    _pending.add(line);
    // Before a sink exists the queue is the only thing holding these, so it
    // gets the same bound; after one exists it is drained within the turn.
    if (_sink == null && _pending.length > capacity) {
      _pending.removeRange(0, _pending.length - capacity);
    }
    _scheduleFlush();
  }

  void clear() => _lines.clear();

  // ---- persistence ---------------------------------------------------------

  /// Attaches to the app's support directory, swallowing anything the platform
  /// throws. Called from `main`, where a logger must not be able to stop the
  /// app from starting.
  Future<void> attachToDefaultDirectory() async {
    try {
      await attachToDirectory(await getApplicationSupportDirectory());
    } catch (e) {
      _fileError = e;
    }
  }

  /// Starts appending to `dir`, rotating the previous run's file aside first.
  ///
  /// The support directory rather than the temporary one: the OS is free to
  /// clear temp whenever it likes, and a log whose whole purpose is surviving
  /// until the tester gets around to sending it cannot live somewhere that
  /// gets swept. The export itself still goes to temp — see [writeReport].
  Future<void> attachToDirectory(Directory dir) async {
    if (_sink != null) return;
    try {
      await dir.create(recursive: true);
      final current = File('${dir.path}/$currentFileName');
      final previous = File('${dir.path}/$previousFileName');
      if (await current.exists()) {
        _recoveredLines = await _countLines(current);
        if (await previous.exists()) await previous.delete();
        await current.rename(previous.path);
      } else if (await previous.exists()) {
        _recoveredLines = await _countLines(previous);
      }
      _dir = dir;
      _sink = current.openWrite(mode: FileMode.writeOnly);
      _sessionBytes = 0;
      _writeToSink('=== session started '
          '${(_startedAt ?? DateTime.now()).toIso8601String()} ===');
      _scheduleFlush();
    } catch (e) {
      // Recording carries on in memory. A tester whose phone will not give us
      // a file is still better served by a shorter report than by a crash.
      _fileError = e;
      _sink = null;
      _dir = null;
    }
  }

  /// Closes the file. Tests use it; the app does not need to, since the point
  /// is to survive not being asked.
  Future<void> detach() async {
    final sink = _sink;
    _sink = null;
    _dir = null;
    if (sink == null) return;
    await _writing;
    try {
      await sink.flush();
      await sink.close();
    } catch (_) {
      // Nothing useful to do with a failure to close a log file.
    }
  }

  void _writeToSink(String line) {
    final sink = _sink;
    if (sink == null) return;
    sink.writeln(line);
    _sessionBytes += line.length + 1;
  }

  /// Batches within one turn of the event loop and then pushes to the OS.
  ///
  /// Once `flush()` has returned, the bytes belong to the kernel, and a
  /// force-stop — which is exactly how these sessions end — cannot take them.
  /// Waiting on a timer instead would trade away the last seconds before the
  /// force-close, which is the part worth having.
  void _scheduleFlush() {
    if (_flushScheduled || _sink == null) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      _writing = _writing.then((_) => _drain());
    });
  }

  Future<void> _drain() async {
    final sink = _sink;
    if (sink == null) return;
    if (_pending.isEmpty) return;
    final batch = List<String>.of(_pending);
    _pending.clear();
    try {
      for (final line in batch) {
        _writeToSink(line);
      }
      await sink.flush();
      if (_sessionBytes >= maxSessionBytes) await _rotate();
    } catch (e) {
      _fileError = e;
    }
  }

  /// Writes everything queued and waits for it to reach the OS.
  Future<void> flush() async {
    if (_sink == null) return;
    _writing = _writing.then((_) => _drain());
    await _writing;
  }

  Future<void> _rotate() async {
    final dir = _dir;
    final sink = _sink;
    if (dir == null || sink == null) return;
    try {
      await sink.flush();
      await sink.close();
      final current = File('${dir.path}/$currentFileName');
      final previous = File('${dir.path}/$previousFileName');
      if (await previous.exists()) await previous.delete();
      if (await current.exists()) await current.rename(previous.path);
      _sink = current.openWrite(mode: FileMode.writeOnly);
      _sessionBytes = 0;
      _writeToSink('=== continued ${DateTime.now().toIso8601String()} ===');
    } catch (e) {
      _fileError = e;
      _sink = null;
    }
  }

  Future<int> _countLines(File file) async {
    try {
      final text = await file.readAsString();
      if (text.isEmpty) return 0;
      return const LineSplitter().convert(text).where((l) => l.isNotEmpty).length;
    } catch (_) {
      return 0;
    }
  }

  /// The tail of a file, capped so one enormous session cannot produce a
  /// report nobody can open.
  Future<String> _readTail(File file, int maxBytes) async {
    try {
      if (!await file.exists()) return '';
      final length = await file.length();
      if (length <= maxBytes) return await file.readAsString();
      final handle = await file.open();
      try {
        await handle.setPosition(length - maxBytes);
        final bytes = await handle.read(maxBytes);
        final text = String.fromCharCodes(bytes);
        // The cut almost certainly lands mid-line; drop that fragment rather
        // than shipping a half-redacted-looking stub.
        final firstBreak = text.indexOf('\n');
        return '...earlier lines dropped...\n'
            '${firstBreak >= 0 ? text.substring(firstBreak + 1) : text}';
      } finally {
        await handle.close();
      }
    } catch (_) {
      return '';
    }
  }

  // ---- rendering -----------------------------------------------------------

  String _header({required Map<String, String> header, required int lineCount, required bool truncated}) {
    final buffer = StringBuffer()
      ..writeln('ANT diagnostics')
      ..writeln('session started: ${_startedAt?.toIso8601String() ?? 'unknown'}')
      ..writeln('written: ${DateTime.now().toIso8601String()}')
      ..writeln('lines: $lineCount${truncated ? ' (oldest dropped)' : ''}');
    if (_recoveredLines > 0) {
      buffer.writeln('recovered from the previous session: $_recoveredLines lines');
    }
    if (_fileError != null) {
      buffer.writeln('NOTE: this session was not written to disk: $_fileError');
    }
    header.forEach((k, v) => buffer.writeln('$k: $v'));
    buffer.writeln();
    if (DiagnosticsConfig.logRawTranscripts) {
      // Said plainly, and at the top. Whoever this file reaches has to know
      // what is in it before they forward it anywhere — and the person whose
      // speech it is cannot read the file to find out.
      buffer
        ..writeln('*** THIS FILE CONTAINS WHAT WAS ACTUALLY SAID. ***')
        ..writeln('Voice transcripts, names, phone numbers, pairing codes,')
        ..writeln('coordinates and account ids appear in full. This build was')
        ..writeln('made that way deliberately, for a known group of testers.')
        ..writeln('Treat it as personal data and do not forward it on.');
    } else {
      buffer
        ..writeln('Transcripts, names, numbers, coordinates and account ids are')
        ..writeln('replaced with their shape before they reach this file.');
    }
    buffer.writeln('-' * 60);
    return buffer.toString();
  }

  /// The whole report, header included — from memory.
  ///
  /// [header] carries build and device facts the tester should not have to
  /// recite — which build, which Android, which handset — since "the latest
  /// one" has already cost a round of confusion once.
  String render({Map<String, String> header = const {}}) {
    final buffer = StringBuffer()
      ..write(_header(
        header: header,
        lineCount: _lines.length,
        truncated: _lines.length >= capacity,
      ));
    for (final line in _lines) {
      buffer.writeln(line);
    }
    return buffer.toString();
  }

  /// The report a tester actually sends: this session *and* the one before it,
  /// read back from disk.
  ///
  /// This is the whole point of item 53. The session worth reporting is
  /// usually the one that ended badly, and by the time the tester reopens the
  /// app to send a report, that session is over.
  Future<String> renderReport({Map<String, String> header = const {}}) async {
    await flush();
    final dir = _dir;
    if (dir == null) return render(header: header);

    final previous = await _readTail(File('${dir.path}/$previousFileName'), maxSessionBytes);
    final current = await _readTail(File('${dir.path}/$currentFileName'), maxSessionBytes);
    if (current.isEmpty && previous.isEmpty) return render(header: header);

    final buffer = StringBuffer()
      ..write(_header(
        header: header,
        lineCount: _lines.length,
        truncated: _lines.length >= capacity,
      ));
    if (previous.isNotEmpty) {
      buffer
        ..writeln('--- the previous session, recovered from disk ---')
        ..writeln(previous.trimRight())
        ..writeln();
    }
    buffer
      ..writeln('--- this session ---')
      ..writeln(current.trimRight());
    return buffer.toString();
  }

  /// Writes the report to a shareable file and returns its path.
  ///
  /// The temporary directory, not the support directory: this is something to
  /// hand to the share sheet and forget, not a file that should accumulate on
  /// the phone of someone who cannot see it to delete it. The *recording*
  /// lives in support — see [attachToDirectory].
  Future<File> writeReport({Map<String, String> header = const {}}) async {
    final text = await renderReport(header: header);
    final dir = await getTemporaryDirectory();
    final at = DateTime.now();
    final name = 'ant-diagnostics-'
        '${at.year}${at.month.toString().padLeft(2, '0')}${at.day.toString().padLeft(2, '0')}-'
        '${at.hour.toString().padLeft(2, '0')}${at.minute.toString().padLeft(2, '0')}.txt';
    final file = File('${dir.path}/$name');
    await file.writeAsString(text);
    return file;
  }
}

/// One per app. Installed from `main` before anything else logs.
final diagnosticsLog = DiagnosticsLog();
