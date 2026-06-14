import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart' as geo;

import 'background_publish.dart';

bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// The background isolate entrypoint. Runs geolocator's movement stream and
/// publishes each fix — alive while the app is foreground, backgrounded, or
/// killed (a sticky foreground service Android restarts after task removal).
@pragma('vm:entry-point')
void onBackgroundStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  StreamSubscription<geo.Position>? sub;
  service.on('stop').listen((_) async {
    await sub?.cancel();
    await service.stopSelf();
  });

  // Publish on movement (15 m). The killed app does nothing else.
  sub = geo.Geolocator.getPositionStream(
    locationSettings: const geo.LocationSettings(distanceFilter: 15),
  ).listen((p) => publishFixInBackground(p.latitude, p.longitude));
}

/// Register the background service. Call once from main(); no-op off Android.
/// `autoStart: false` — we only run it while live sharing is on.
Future<void> configureBackgroundService() async {
  if (!_supported) return;
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundStart,
      autoStart: false,
      autoStartOnBoot: true,
      isForegroundMode: true,
      initialNotificationTitle: 'Position',
      initialNotificationContent: 'Sharing your location with your group',
      foregroundServiceTypes: const [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

/// Start movement-triggered background publishing. No-op off Android / if running.
Future<void> startBackgroundPublishing() async {
  if (!_supported) return;
  final service = FlutterBackgroundService();
  if (await service.isRunning()) return;
  await service.startService();
}

/// Stop background publishing. No-op if not running / unsupported.
Future<void> stopBackgroundPublishing() async {
  if (!_supported) return;
  final service = FlutterBackgroundService();
  if (await service.isRunning()) service.invoke('stop');
}
