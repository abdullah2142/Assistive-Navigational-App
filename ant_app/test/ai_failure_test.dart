import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/ai_failure.dart';

void main() {
  test('failures are told apart', () {
    expect(classifyAiFailure(TimeoutException('x')), AiFailureKind.timeout);
    expect(classifyAiFailure(const SocketException('Failed host lookup')), AiFailureKind.offline);
    expect(classifyAiFailure(Exception('HTTP 429 quota exceeded')), AiFailureKind.busy);
    expect(classifyAiFailure(Exception('The model is overloaded (503)')), AiFailureKind.busy);
    expect(classifyAiFailure(Exception('something odd')), AiFailureKind.other);
  });

  for (final l in AppLanguage.values) {
    test('[${l.name}] each cause has its own sentence and names what still works', () {
      final d = Dashboard.of(l);
      final all = {for (final k in AiFailureKind.values) d.aiFailureReply(k)};
      expect(all.length, AiFailureKind.values.length);
      for (final r in all) {
        expect(r, isNot(contains('Got it')));
      }
    });
  }
}
