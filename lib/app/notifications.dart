import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// "Your move" alerts shown when the app isn't in front: after the computer's turn in a solo game,
/// and when a move arrives over a link while the app is in the background.
class Notifications {
  Notifications._();
  static final Notifications shared = Notifications._();
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
        ),
      );
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  Future<bool> requestPermission() async {
    if (!_ready) return false;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) return await android.requestNotificationsPermission() ?? false;
      final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) return await ios.requestPermissions(alert: true, sound: true, badge: true) ?? false;
    } catch (_) {}
    return false;
  }

  Future<void> yourMove({required String title, required String body}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: 1,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails('turns', 'Your move', channelDescription: 'When it is your turn', importance: Importance.high, priority: Priority.high),
          iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
        ),
      );
    } catch (_) {}
  }
}
