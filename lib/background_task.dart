import 'package:background_locator_2/background_locator.dart';
import 'package:background_locator_2/location_dto.dart';
import 'package:background_locator_2/settings/android_settings.dart';
import 'package:background_locator_2/settings/locator_settings.dart';
import 'package:flutter/foundation.dart';

import 'background_publish.dart';

bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Fired by background_locator_2 in its own isolate whenever the device moves
/// past the distance filter — even with the app backgrounded or killed. The
/// only thing the killed app does: publish this fix, then go back to sleep.
@pragma('vm:entry-point')
Future<void> backgroundLocationCallback(LocationDto loc) async {
  await publishFixInBackground(loc.latitude, loc.longitude);
}

@pragma('vm:entry-point')
void backgroundInitCallback(Map<String, dynamic> _) {}

@pragma('vm:entry-point')
void backgroundDisposeCallback() {}

/// Start movement-triggered background publishing. Android only and idempotent;
/// a no-op elsewhere. Needs the user to have granted "Allow all the time".
Future<void> startBackgroundPublishing() async {
  if (!_supported) return;
  if (await BackgroundLocator.isRegisterLocationUpdate()) return;
  await BackgroundLocator.initialize();
  await BackgroundLocator.registerLocationUpdate(
    backgroundLocationCallback,
    initCallback: backgroundInitCallback,
    disposeCallback: backgroundDisposeCallback,
    autoStop: false,
    androidSettings: const AndroidSettings(
      accuracy: LocationAccuracy.NAVIGATION,
      interval: 10,
      distanceFilter: 15, // metres of movement before we publish again
      client: LocationClient.android,
      androidNotificationSettings: AndroidNotificationSettings(
        notificationChannelName: 'Position',
        notificationTitle: 'Position',
        notificationMsg: 'Sharing your location with your group',
        notificationBigMsg:
            'Position publishes your location to your group as you move, even when the app is closed.',
      ),
    ),
  );
}

/// Stop background publishing. No-op if not running / unsupported.
Future<void> stopBackgroundPublishing() async {
  if (!_supported) return;
  if (await BackgroundLocator.isRegisterLocationUpdate()) {
    await BackgroundLocator.unRegisterLocationUpdate();
  }
}
