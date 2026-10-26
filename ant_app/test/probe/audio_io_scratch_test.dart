import 'package:ant_app/core/utils/spoken_text.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('scratch', () {
    final ins = [
      'See https://maps.google.com/?q=23.7,90.4 now',
      'Walk 3.5 km then 1,000 m',
      '১২৩ নম্বর বাস, ৫০০ মিটার',
      '- 5 degrees\n- 10 meters',
      'Temp -5°C',
      'Bus 5 → Farmgate ⚠️ danger',
      '2 * 3 and 4 * 5',
      'file_name_here and _x_',
      '1️⃣ left',
      '  \n\n ',
      '⚠️',
      '**Stop!** Car coming!!!',
      'a\nb',
      'Call 999.',
      '10. Turn left\n11. Turn right',
      '.5 km away',
      '> 5 minutes',
      'Cost: 5 < 6 | 7',
      'শেষ।।',
      'Wait... no',
      'Dr. Rahman, 3 p.m.',
      'a ... b',
      '1.2.3 version',
    ];
    for (final s in ins) { print('${s.replaceAll("\n", "\\n")}  =>  [${forSpeech(s)}]'); }
  });
}
