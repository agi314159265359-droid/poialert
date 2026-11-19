import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/poi_model.dart';
import 'notification_service.dart';

class AlertService {
  static final AlertService _instance = AlertService._internal();
  factory AlertService() => _instance;
  AlertService._internal();

  final FlutterTts _tts = FlutterTts();
  final NotificationService _notificationService = NotificationService();

  /// Completer that resolves when the current TTS utterance finishes.
  /// map_screen listens to this to auto-dismiss the foreground alert popup.
  final StreamController<void> _alertCompleteController =
      StreamController<void>.broadcast();
  Stream<void> get onAlertComplete => _alertCompleteController.stream;

  // Track which POIs have been alerted
  final Set<String> _alertedPOIs = {};

  // Cooldown period (seconds) before re-alerting same POI
  final int _cooldownSeconds = 300; // 5 minutes

  Future<void> initialize() async {
    await _notificationService.initialize();

    // Configure TTS
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5); // moderate pace, clear for driving
    await _tts.setPitch(1.1); // slightly elevated for urgency
    await _tts.setVolume(1.0);

    // Listen for TTS completion to fire the onAlertComplete stream
    _tts.setCompletionHandler(() {
      _alertCompleteController.add(null);
    });
  }

  // Check if user is within alert distance of POI
  bool shouldAlert(POI poi, double distanceInMeters) {
    if (distanceInMeters > poi.alertDistance) {
      // User is far from POI, remove from alerted list
      _alertedPOIs.remove(poi.id);
      return false;
    }

    if (_alertedPOIs.contains(poi.id)) {
      // Already alerted for this POI
      return false;
    }

    return true;
  }

  /// Trigger alert for POI.
  ///
  /// [distance] - current distance in meters from the user to the POI.
  /// [isApproaching] - whether the user is heading toward this POI.
  Future<void> triggerAlert(
    POI poi,
    BuildContext? context, {
    double? distance,
    bool isApproaching = false,
  }) async {
    // Mark as alerted
    _alertedPOIs.add(poi.id);

    // Speak the alert via TTS (most important)
    await _speak(poi, distance: distance, isApproaching: isApproaching);

    // Vibrate
    await _vibrate();

    // Build a descriptive notification body
    final String distText = distance != null ? '${distance.round()}m' : '';
    final String dirText = isApproaching ? 'ahead' : 'nearby';
    final String notifBody = distText.isNotEmpty
        ? '${_friendlyTypeName(poi.type)} $dirText — $distText'
        : poi.alertMessage;

    // Show notification (for background)
    await _notificationService.showProximityAlert(
      title: '⚠️ DANGER ZONE ALERT',
      body: notifBody,
      poiId: poi.id,
    );

    // Save alert history
    await _saveAlertHistory(poi);

    // Auto-remove from alerted list after cooldown
    Future.delayed(Duration(seconds: _cooldownSeconds), () {
      _alertedPOIs.remove(poi.id);
    });
  }

  /// Compose and speak a direction-aware TTS message.
  Future<void> _speak(
    POI poi, {
    double? distance,
    bool isApproaching = false,
  }) async {
    try {
      // Stop any currently playing utterance
      await _tts.stop();

      // Only speak "Caution ahead"
      const String message = 'Caution ahead';

      await _tts.speak(message);
      print('🗣️ TTS: $message');
    } catch (e) {
      print('❌ TTS error: $e');
      // Fallback to haptic if TTS fails
      try {
        await HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 100));
        await HapticFeedback.heavyImpact();
      } catch (e2) {
        print('❌ Fallback haptic also failed: $e2');
      }
    }
  }

  /// Map POI type codes to human-readable spoken names.
  String _friendlyTypeName(String type) {
    switch (type) {
      case 'yellow_box':
        return 'Yellow box junction';
      case 'school_street':
        return 'School street zone';
      case 'ltn':
        return 'Low traffic neighbourhood';
      case 'no_entry':
        return 'No entry zone';
      case 'no_right_turn':
        return 'No right turn';
      case 'no_left_turn':
        return 'No left turn';
      case 'no_u_turn':
        return 'No U turn';
      case 'restricted_route':
        return 'Restricted route';
      case 'pedestrian_zone':
        return 'Pedestrian zone';
      default:
        return 'Traffic restriction';
    }
  }

  Future<void> _vibrate() async {
    try {
      await HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 200));
      await HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 200));
      await HapticFeedback.heavyImpact();
    } catch (e) {
      print('Error vibrating: $e');
    }
  }

  Future<void> _saveAlertHistory(POI poi) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> history = prefs.getStringList('alert_history') ?? [];

      String entry = '${DateTime.now().toIso8601String()}|${poi.name}|${poi.id}';
      history.insert(0, entry);

      // Keep only last 50 alerts
      if (history.length > 50) {
        history = history.sublist(0, 50);
      }

      await prefs.setStringList('alert_history', history);
    } catch (e) {
      print('Error saving alert history: $e');
    }
  }

  // Reset alerted POIs (for testing)
  void resetAlerts() {
    _alertedPOIs.clear();
  }

  void dispose() {
    _tts.stop();
    _alertCompleteController.close();
  }
}