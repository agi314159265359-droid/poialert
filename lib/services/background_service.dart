import 'dart:async';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/london_pois.dart';
import '../models/poi_model.dart';

class BackgroundService {
  static final BackgroundService _instance = BackgroundService._internal();
  factory BackgroundService() => _instance;
  BackgroundService._internal();

  Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    // Create notification channel for foreground service
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'poi_tracking_channel',
      'POI Location Tracking',
      description: 'Tracks your location to alert you of nearby danger zones',
      importance: Importance.low,
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'poi_tracking_channel',
        initialNotificationTitle: 'POI Alert',
        initialNotificationContent: 'Tracking your location...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  Future<void> startService() async {
    final service = FlutterBackgroundService();
    var isRunning = await service.isRunning();
    if (!isRunning) {
      service.startService();
    }
  }

  Future<void> stopService() async {
    final service = FlutterBackgroundService();
    service.invoke("stop");
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

    // Listen for stop command
    service.on('stop').listen((event) {
      service.stopSelf();
    });

    // Track location and check proximity
    Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          try {
            // Get current position
            Position position = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.high,
            );

            // Load POIs — the background isolate cannot access Supabase
            // (no initialized client), so we use the offline fallback list.
            // The foreground MapScreen handles live DB queries while the app
            // is open; this background loop acts as a safety-net notifier.
            List<POI> pois = [LondonPOIs.demoFallback];


            // Check each POI
            for (POI poi in pois) {
              double distance = Geolocator.distanceBetween(
                position.latitude,
                position.longitude,
                poi.latitude,
                poi.longitude,
              );

              // If within alert distance
              if (distance <= poi.alertDistance) {
                // Check if already alerted
                final prefs = await SharedPreferences.getInstance();
                String key = 'alerted_${poi.id}';
                bool alreadyAlerted = prefs.getBool(key) ?? false;

                if (!alreadyAlerted) {
                  // Show notification
                  await _showBackgroundAlert(
                    flutterLocalNotificationsPlugin,
                    poi,
                    distance,
                  );

                  // Mark as alerted
                  await prefs.setBool(key, true);

                  // Reset after 5 minutes
                  Future.delayed(const Duration(minutes: 5), () async {
                    await prefs.setBool(key, false);
                  });
                }
              } else {
                // Reset alert if far away
                final prefs = await SharedPreferences.getInstance();
                String key = 'alerted_${poi.id}';
                await prefs.setBool(key, false);
              }
            }

            // Update foreground notification
            service.setForegroundNotificationInfo(
              title: "POI Alert Active",
              content: "Monitoring ${pois.length} danger zones",
            );
          } catch (e) {
            print('Background tracking error: $e');
          }
        }
      }
    });
  }

  static Future<void> _showBackgroundAlert(
      FlutterLocalNotificationsPlugin notifications,
      POI poi,
      double distance,
      ) async {
    AndroidNotificationDetails androidDetails =
    AndroidNotificationDetails(
      'poi_alerts',
      'POI Alerts',
      channelDescription: 'Proximity alerts for danger zones',
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
      sound: const RawResourceAndroidNotificationSound('alert'),
    );

    NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );

    await notifications.show(
      poi.id.hashCode,
      '⚠️ DANGER ZONE ALERT',
      '${poi.name} - ${distance.round()}m away\n${poi.alertMessage}',
      notificationDetails,
    );
  }
}