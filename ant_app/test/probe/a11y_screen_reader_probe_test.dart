import 'dart:async';
import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/models/hazard_report.dart';
import 'package:ant_app/features/dashboard/providers/dashboard_providers.dart';
import 'package:ant_app/features/dashboard/services/hazard_report_service.dart';
import 'package:ant_app/features/dashboard/widgets/crowdsource_reporting_hub.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void dumpTree(SemanticsNode n, [int d = 0]) {
  final data = n.getSemanticsData();
  final f = data.flagsCollection;
  // ignore: avoid_print
  print('${'  ' * d}[${data.label.replaceAll('\n', ' | ')}] val=${data.value} hint=${data.hint} '
      '${f.isButton ? 'BTN ' : ''}${f.isTextField ? 'TF ' : ''}${f.isSlider ? 'SLIDER ' : ''}${f.isLiveRegion ? 'LIVE ' : ''}${f.isHeader ? 'HDR ' : ''}${f.isEnabled.toString().contains('false')?'DISABLED ':''}${data.hasAction(SemanticsAction.tap) ? 'tap ' : ''}');
  n.visitChildren((c) { dumpTree(c, d + 1); return true; });
}
void dump(WidgetTester t) => dumpTree(t.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);

class _Tts implements TtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async { spoken.add(text); }
  @override
  Future<void> stop() async {}
  @override
  void setVoiceId(String voiceId) {}
}
class _Stt extends SttService {
  @override
  Future<bool> ensureAvailable() async => true;
  @override
  Future<void> listenOnce({required AppLanguage language, required void Function(String, bool) onResult, Duration pauseFor = const Duration(seconds: 3), Duration listenFor = const Duration(minutes: 5), Duration? initialSilence, List<String> phraseHints = const []}) async {}
  @override
  Future<void> stop() async {}
}
class _Reports implements HazardReportService {
  @override
  Future<void> submitReport(HazardReport report) => Completer<int>().future;
}

void main() {
  testWidgets('explore hub', (tester) async {
    final h = tester.ensureSemantics();
    final d = Dashboard.of(AppLanguage.bangla);
    await tester.pumpWidget(ProviderScope(
      overrides: [hazardReportServiceProvider.overrideWithValue(_Reports()), ttsServiceProvider.overrideWithValue(_Tts()), sttServiceProvider.overrideWithValue(_Stt())],
      child: const MaterialApp(home: CrowdsourceReportingHub(reporterUid: 'u1', language: AppLanguage.bangla, voiceAutoListen: false))));
    await tester.pump();
    print('--- step1'); dump(tester);
    await tester.tap(find.text(d.hazardCategoryLabel(HazardCategory.roadHazard)));
    await tester.pump();
    print('--- step2'); dump(tester);
    final firstSub = d.hazardSubCategoryKeys(HazardCategory.roadHazard).firstWhere((k) => !d.isOtherSubCategoryKey(k));
    await tester.tap(find.text(d.hazardSubCategoryLabel(firstSub)));
    await tester.pump();
    print('--- step3'); dump(tester);
    await tester.tap(find.text(d.crowdsourceSubmitButton));
    await tester.pump(const Duration(milliseconds: 100));
    print('--- submitting'); dump(tester);
    h.dispose();
    await tester.pump(const Duration(seconds: 40));
  });
}
