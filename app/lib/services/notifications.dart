import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../domain/notification_plan.dart';

/// All reminders are scheduled ON-DEVICE. Re-planned whenever data changes.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('America/New_York'));
    }
    await _plugin.initialize(settings: const InitializationSettings(iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false)));
    _ready = true;
  }

  Future<bool> requestPermission() async {
    await init();
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    return await ios?.requestPermissions(alert: true, sound: true, badge: false) ?? false;
  }

  Future<void> apply(List<PlannedNotification> plan) async {
    try {
      await init();
      await _plugin.cancelAll();
      for (final n in plan) {
        await _plugin.zonedSchedule(
          id: n.id, title: n.title, body: n.body, scheduledDate: tz.TZDateTime.from(n.when, tz.local),
          notificationDetails: const NotificationDetails(iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true)),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: n.repeatWeekly ? DateTimeComponents.dayOfWeekAndTime : null,
        );
      }
    } catch (_) {
      // Notifications are a convenience; never break the app.
    }
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) => NotificationService());
