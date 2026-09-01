import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/hazard_report_service.dart';

final hazardReportServiceProvider = Provider<HazardReportService>((ref) => HazardReportService());
