import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/diagnostics/diagnostics_log.dart';
import '../../../core/localization/dashboard_strings.dart';

/// "Send a report to the developers" — the end of a tester session.
///
/// Exists because the alternative is `adb logcat`, and the people testing this
/// app are not at a desk with a cable. One device session with a log settled
/// more than a week of guessing at item 31; this is that, without the cable.
///
/// The share sheet rather than an upload: it costs no backend, no consent
/// screen of its own and no storage of somebody else's data, and the tester
/// can see exactly what they are sending and to whom before it goes.
class DiagnosticsReportTile extends StatefulWidget {
  const DiagnosticsReportTile({super.key, required this.strings});

  final Dashboard strings;

  @override
  State<DiagnosticsReportTile> createState() => _DiagnosticsReportTileState();
}

class _DiagnosticsReportTileState extends State<DiagnosticsReportTile> {
  bool _busy = false;

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      // Facts the tester should not have to recite. "The latest one" has
      // already cost a round of confusion about which build was being tested.
      final info = await PackageInfo.fromPlatform();
      final file = await diagnosticsLog.writeReport(header: {
        'app': '${info.version}+${info.buildNumber}',
        'package': info.packageName,
      });
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'ANT diagnostics'),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(widget.strings.settingsDiagnosticsFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.strings;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(d.settingsDiagnosticsHint, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Text(
          d.settingsDiagnosticsReady(diagnosticsLog.length),
          style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
        ),
        // Item 53: the session worth reporting is usually the one that ended
        // badly, and it is over by the time the tester gets here. Saying so
        // is what stops them reporting from memory instead.
        if (diagnosticsLog.recoveredLines > 0)
          Text(
            d.settingsDiagnosticsRecovered(diagnosticsLog.recoveredLines),
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
          ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: _busy ? null : _send,
            icon: _busy
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share_rounded),
            label: Text(d.settingsDiagnosticsButton),
          ),
        ),
      ],
    );
  }
}
