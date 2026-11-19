import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';

class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  StreamController<Position>? _positionController;
  StreamSubscription<Position>? _positionSubscription;

  Stream<Position> get positionStream {
    _positionController ??= StreamController<Position>.broadcast();
    return _positionController!.stream;
  }

  // Check if location services are enabled
  Future<bool> isLocationServiceEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  // Check location permissions
  Future<bool> hasPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  // Request location permissions
  Future<bool> requestPermission() async {
    // First check if service is enabled
    bool serviceEnabled = await isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    // Check current permission
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      // Open app settings
      await openAppSettings();
      return false;
    }

    // Request background location for Android
    if (permission == LocationPermission.whileInUse) {
      var status = await Permission.locationAlways.request();
      if (!status.isGranted) {
        // It's okay, we can still work with whileInUse
      }
    }

    return true;
  }

  // Get current position once
  Future<Position?> getCurrentPosition() async {
    try {
      bool hasPermission = await this.hasPermission();
      if (!hasPermission) {
        hasPermission = await requestPermission();
        if (!hasPermission) return null;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      return position;
    } catch (e) {
      print('Error getting position: $e');
      return null;
    }
  }

  // Start continuous location tracking
  Future<void> startTracking() async {
    bool hasPermission = await this.hasPermission();
    if (!hasPermission) {
      hasPermission = await requestPermission();
      if (!hasPermission) return;
    }

    late final LocationSettings locationSettings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1, // Update every 1 meter
        forceLocationManager: false,
        intervalDuration: const Duration(seconds: 1),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 1,
        pauseLocationUpdatesAutomatically: false,
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      );
    }

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) {
        _positionController?.add(position);
      },
      onError: (error) {
        print('Location stream error: $error');
      },
    );
  }

  // Stop tracking
  void stopTracking() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  // Calculate distance between two points in meters
  double calculateDistance(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) {
    return Geolocator.distanceBetween(
      startLat,
      startLng,
      endLat,
      endLng,
    );
  }

  // Format distance for display
  String formatDistance(double distanceInMeters) {
    if (distanceInMeters < 1000) {
      return '${distanceInMeters.round()}m';
    } else {
      return '${(distanceInMeters / 1000).toStringAsFixed(1)}km';
    }
  }

  // Cleanup
  void dispose() {
    _positionSubscription?.cancel();
    _positionController?.close();
  }
}
