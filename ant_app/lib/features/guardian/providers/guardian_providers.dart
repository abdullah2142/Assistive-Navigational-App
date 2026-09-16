import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/communication_message.dart';
import '../models/guardian_alert.dart';
import '../models/live_location.dart';
import '../services/alert_service.dart';
import '../services/communication_service.dart';
import '../services/live_location_publisher.dart';
import '../services/live_location_service.dart';

final liveLocationServiceProvider = Provider<LiveLocationService>((ref) => LiveLocationService());

/// Publishes this device's position for its caretaker to read — item 58.
///
/// One per app, and disposed with the provider container, so the stream is
/// never left running by a screen that forgot to stop it.
final liveLocationPublisherProvider = Provider<LiveLocationPublisher>((ref) {
  final publisher = LiveLocationPublisher();
  ref.onDispose(publisher.stop);
  return publisher;
});
final alertServiceProvider = Provider<AlertService>((ref) => AlertService());
final communicationServiceProvider = Provider<CommunicationService>((ref) => CommunicationService());

final liveLocationStreamProvider = StreamProvider.family<LiveLocation?, String>((ref, disabledUserUid) {
  return ref.watch(liveLocationServiceProvider).watchLocation(disabledUserUid);
});

final alertsStreamProvider = StreamProvider.family<List<GuardianAlert>, String>((ref, disabledUserUid) {
  return ref.watch(alertServiceProvider).watchAlerts(disabledUserUid);
});

final communicationsStreamProvider = StreamProvider.family<List<CommunicationMessage>, String>((ref, disabledUserUid) {
  return ref.watch(communicationServiceProvider).watchMessages(disabledUserUid);
});
