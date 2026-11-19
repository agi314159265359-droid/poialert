import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:math' as math;
import '../services/background_service.dart';
import '../utils/colors.dart';
import '../data/london_pois.dart';
import '../models/poi_model.dart';
import '../services/location_service.dart';
import '../services/alert_service.dart';
import '../services/poi_repository.dart';
import 'poi_details_screen.dart';
import 'settings_screen.dart';

/// Temporary debug flag — set to false (or remove) before shipping to client.
const bool kShowDebugOverlay = false;

/// GPS accuracy threshold for alert triggering (meters).
/// Readings with accuracy worse than this are skipped for alerting,
/// but still used for UI (map dot, distances, POI list).
const double kMaxAcceptableAccuracy = 75.0;

/// If no good-accuracy reading arrives within this window, fall back to
/// firing alerts on the best available (low-confidence) reading anyway.
/// Prevents total silence in genuine urban-canyon conditions.
const int kAccuracyFallbackSeconds = 20;

/// Angular threshold (degrees) for approach detection.
/// If the difference between user heading and bearing-to-POI is ≤ this,
/// the user is considered to be heading toward the POI.
const double kApproachAngleThreshold = 30.0;

/// Minimum speed (m/s) before heading is considered reliable.
/// Below ~1 m/s the device heading can jump randomly.
const double kMinSpeedForHeading = 0.5;

class MapScreen extends StatefulWidget {
  const MapScreen({Key? key}) : super(key: key);

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  // --- Services ---
  final LocationService _locationService = LocationService();
  final AlertService _alertService = AlertService();
  final BackgroundService _backgroundService = BackgroundService();
  final PoiRepository _poiRepository = PoiRepository();

  // --- State ---
  List<POI> _pois = [];
  Position? _currentPosition;
  bool _showAlert = false;
  POI? _currentAlertPOI;
  bool _isLoading = true;
  bool _locationPermissionGranted = false;
  String _statusMessage = 'Initializing...';
  bool _supabaseConnected = false;
  bool _isFetchingPois = false;

  // --- Alert distance (loaded from SharedPreferences) ---
  int _alertDistance = 150;

  // --- Query throttle ---
  DateTime? _lastQueryTime;
  Position? _lastQueryPosition;
  static const int _queryIntervalSeconds = 30;
  static const double _queryMoveThresholdMeters = 300;

  // --- Tracking ---
  StreamSubscription<Position>? _positionSubscription;

  // --- Google Map controller ---
  GoogleMapController? _mapController;

  // --- Auto-dismiss timer for the foreground alert popup ---
  Timer? _alertDismissTimer;
  StreamSubscription<void>? _alertCompleteSubscription;
  Map<String, double> _distances = {};

  // --- Debug overlay: flash red when an alert fires ---
  bool _debugAlertFlash = false;
  Timer? _debugFlashTimer;

  // --- GPS accuracy filtering ---
  bool _lastTickAccepted = true;
  bool _lastTickWasFallback = false;
  DateTime _lastAcceptedTime = DateTime.now();

  // --- Direction tracking ---
  double _userHeading = 0.0;
  bool _hasReliableHeading = false;
  Position? _previousPosition;
  Map<String, bool> _approachingStatus = {};

  // --- Auto-follow camera (navigation mode) ---
  bool _isAutoFollow = true;
  Timer? _autoRecenterTimer;
  static const double _autoFollowZoom = 17.2;
  static const double _autoFollowTilt = 15.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSubscription?.cancel();
    _autoRecenterTimer?.cancel();
    _alertDismissTimer?.cancel();
    _alertCompleteSubscription?.cancel();
    _debugFlashTimer?.cancel();
    _mapController?.dispose();
    _backgroundService.stopService();
    _alertService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkLocationAndStartTracking();
    }
  }

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  Future<void> _initializeApp() async {
    await _alertService.initialize();
    await _backgroundService.initializeService();
    await _loadAlertDistance();
    await _checkLocationAndStartTracking();
  }

  Future<void> _loadAlertDistance() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble('alert_distance') ?? 150.0;
    setState(() {
      _alertDistance = saved.clamp(50.0, 500.0).toInt();
    });
  }

  Future<void> _checkLocationAndStartTracking() async {
    setState(() => _statusMessage = 'Checking location services...');

    bool serviceEnabled = await _locationService.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _isLoading = false;
        _statusMessage = 'Location services disabled';
      });
      _showLocationServiceDialog();
      return;
    }

    setState(() => _statusMessage = 'Requesting permissions...');

    bool hasPermission = await _locationService.requestPermission();
    if (!hasPermission) {
      setState(() {
        _isLoading = false;
        _locationPermissionGranted = false;
        _statusMessage = 'Location permission denied';
      });
      _showPermissionDialog();
      return;
    }

    setState(() {
      _locationPermissionGranted = true;
      _statusMessage = 'Getting your location...';
    });

    Position? position = await _locationService.getCurrentPosition();
    if (position != null) {
      setState(() {
        _currentPosition = position;
        _isLoading = false;
        _statusMessage = 'Tracking active';
      });
    } else {
      setState(() {
        _isLoading = false;
        _statusMessage = 'Tracking active';
      });
    }

    if (_locationPermissionGranted && _currentPosition != null) {
      await _backgroundService.startService();
      // Trigger first POI fetch immediately
      await _fetchNearbyPois(_currentPosition!);
    }

    _startLocationTracking();
  }

  // ---------------------------------------------------------------------------
  // Location tracking loop
  // ---------------------------------------------------------------------------

  void _startLocationTracking() {
    _positionSubscription?.cancel();
    _locationService.startTracking();

    _positionSubscription = _locationService.positionStream.listen(
      (Position position) {
        // Calculate reliable heading:
        double heading = position.heading;
        bool reliable = false;

        // If Android GPS didn't provide heading (often 0.0 on bike/starting),
        // calculate mathematical bearing from previous GPS point:
        if (_previousPosition != null) {
          final double distMoved = _locationService.calculateDistance(
            _previousPosition!.latitude,
            _previousPosition!.longitude,
            position.latitude,
            position.longitude,
          );
          if (distMoved >= 2.0) {
            final double computedBearing = _calculateBearing(
              _previousPosition!.latitude,
              _previousPosition!.longitude,
              position.latitude,
              position.longitude,
            );
            // Use sensor heading if positive, otherwise use computed bearing
            heading = (heading > 0.0) ? heading : computedBearing;
            reliable = true;
          } else {
            // Stopped or slow: maintain last known heading
            heading = _userHeading;
            reliable = _hasReliableHeading;
          }
        } else if (heading > 0.0) {
          reliable = true;
        }

        setState(() {
          _currentPosition = position;
          _userHeading = heading;
          _hasReliableHeading = reliable;
        });

        _previousPosition = position;
        _calculateDistances();
        _updateApproachStatus();

        // Auto-follow camera: keep user centered with heading rotation
        if (_isAutoFollow && _mapController != null) {
          _mapController!.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(
                target: LatLng(position.latitude, position.longitude),
                zoom: _autoFollowZoom,
                bearing: _hasReliableHeading ? _userHeading : 0.0,
                tilt: _autoFollowTilt,
              ),
            ),
          );
        }

        // --- Accuracy gate: only trigger alerts on confident readings ---
        final bool goodAccuracy =
            position.accuracy <= kMaxAcceptableAccuracy;
        final bool fallback = !goodAccuracy &&
            DateTime.now().difference(_lastAcceptedTime).inSeconds >=
                kAccuracyFallbackSeconds;

        if (goodAccuracy) {
          _lastAcceptedTime = DateTime.now();
          _lastTickAccepted = true;
          _lastTickWasFallback = false;
          _checkProximityAlerts();
        } else if (fallback) {
          // Extended poor accuracy — fire anyway to avoid total silence
          _lastTickAccepted = false;
          _lastTickWasFallback = true;
          _checkProximityAlerts();
          print('[MapScreen] Accuracy fallback: acc=${position.accuracy.toStringAsFixed(1)}m, '
              'no good reading for ${kAccuracyFallbackSeconds}s — firing alert check anyway');
        } else {
          _lastTickAccepted = false;
          _lastTickWasFallback = false;
        }

        _maybeRefreshPois(position);
      },
      onError: (error) {
        print('[MapScreen] Position stream error: $error');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Supabase query + throttle
  // ---------------------------------------------------------------------------

  /// Decides whether to re-query Supabase based on time elapsed and distance
  /// moved since last query. This prevents hammering the DB on every GPS tick.
  void _maybeRefreshPois(Position position) {
    if (_isFetchingPois) return;

    final now = DateTime.now();
    bool shouldFetch = false;

    if (_lastQueryTime == null) {
      shouldFetch = true; // first fetch
    } else {
      final elapsed = now.difference(_lastQueryTime!).inSeconds;
      if (elapsed >= _queryIntervalSeconds) {
        shouldFetch = true;
      } else if (_lastQueryPosition != null) {
        final moved = _locationService.calculateDistance(
          _lastQueryPosition!.latitude,
          _lastQueryPosition!.longitude,
          position.latitude,
          position.longitude,
        );
        if (moved >= _queryMoveThresholdMeters) {
          shouldFetch = true;
        }
      }
    }

    if (shouldFetch) {
      _fetchNearbyPois(position);
    }
  }

  Future<void> _fetchNearbyPois(Position position) async {
    if (_isFetchingPois) return;
    _isFetchingPois = true;

    // query radius = alert distance + 300 m buffer so POIs are cached
    // before the user is close enough to trigger an alert
    final int queryRadius = _alertDistance + 800;

    final List<POI> fetched = await _poiRepository.getNearbyPois(
      position.latitude,
      position.longitude,
      radiusMeters: queryRadius,
    );

    if (!mounted) return;

    // Update throttle trackers regardless of result
    _lastQueryTime = DateTime.now();
    _lastQueryPosition = position;
    _isFetchingPois = false;

    if (fetched.isEmpty && _pois.isNotEmpty) {
      // Keep the existing cache; don't blank the map on a quiet area
      print('[MapScreen] No POIs in range — keeping existing cache');
      return;
    }

    setState(() {
      if (fetched.isNotEmpty || _pois.isEmpty) {
        _pois = fetched;
      }
      _supabaseConnected = true;
    });

    // Recalculate distances against the fresh list
    _calculateDistances();
  }

  // ---------------------------------------------------------------------------
  // Bearing & approach detection
  // ---------------------------------------------------------------------------

  /// Calculate bearing (0–360°) from point A to point B using the
  /// standard forward-azimuth formula.
  double _calculateBearing(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final double dLng = _toRadians(lng2 - lng1);
    final double lat1R = _toRadians(lat1);
    final double lat2R = _toRadians(lat2);

    final double x = math.sin(dLng) * math.cos(lat2R);
    final double y = math.cos(lat1R) * math.sin(lat2R) -
        math.sin(lat1R) * math.cos(lat2R) * math.cos(dLng);

    final double bearing = math.atan2(x, y);
    return (_toDegrees(bearing) + 360) % 360;
  }

  double _toRadians(double deg) => deg * math.pi / 180.0;
  double _toDegrees(double rad) => rad * 180.0 / math.pi;

  /// Returns true if the user's current heading is within
  /// [kApproachAngleThreshold]° of the bearing to [poi].
  bool _isApproaching(POI poi) {
    if (!_hasReliableHeading || _currentPosition == null) return false;

    final double bearing = _calculateBearing(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      poi.latitude,
      poi.longitude,
    );

    double diff = (_userHeading - bearing).abs();
    if (diff > 180) diff = 360 - diff;

    return diff <= kApproachAngleThreshold;
  }

  /// Recalculate approach status for all cached POIs.
  void _updateApproachStatus() {
    final Map<String, bool> updated = {};
    for (final POI poi in _pois) {
      updated[poi.id] = _isApproaching(poi);
    }
    setState(() => _approachingStatus = updated);
  }

  // ---------------------------------------------------------------------------
  // Proximity logic
  // ---------------------------------------------------------------------------

  void _calculateDistances() {
    if (_currentPosition == null) return;

    final Map<String, double> updated = {};
    for (final POI poi in _pois) {
      updated[poi.id] = _locationService.calculateDistance(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        poi.latitude,
        poi.longitude,
      );
    }
    setState(() => _distances = updated);
  }

  void _checkProximityAlerts() {
    if (_currentPosition == null) return;

    for (final POI poi in _pois) {
      final double distance = _distances[poi.id] ?? double.infinity;
      // Use the saved alert distance rather than the per-POI default
      final effectivePoi = _alertDistance != poi.alertDistance
          ? POI(
              id: poi.id,
              name: poi.name,
              description: poi.description,
              latitude: poi.latitude,
              longitude: poi.longitude,
              type: poi.type,
              alertMessage: poi.alertMessage,
              alertDistance: _alertDistance,
              council: poi.council,
              street: poi.street,
              adjoiningStreet: poi.adjoiningStreet,
              schoolName: poi.schoolName,
            )
          : poi;

      if (_alertService.shouldAlert(effectivePoi, distance)) {
        _showProximityAlert(effectivePoi);
        final bool approaching = _approachingStatus[poi.id] ?? false;
        _alertService.triggerAlert(
          effectivePoi,
          context,
          distance: distance,
          isApproaching: approaching,
        );
        break; // Only one alert at a time
      }
    }
  }

  void _showProximityAlert(POI poi) {
    setState(() {
      _showAlert = true;
      _currentAlertPOI = poi;
      // Flash the debug overlay red for 2 seconds
      if (kShowDebugOverlay) {
        _debugAlertFlash = true;
        _debugFlashTimer?.cancel();
        _debugFlashTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _debugAlertFlash = false);
        });
      }
    });
    _startAlertAutoDismiss();
  }

  /// Listens for the alert sound to finish then waits a further 500 ms
  /// (to let the vibration complete) before auto-closing the overlay.
  /// Cancels any previously running timer so rapid successive alerts don't
  /// leave stale timers behind.
  void _startAlertAutoDismiss() {
    _alertDismissTimer?.cancel();
    _alertCompleteSubscription?.cancel();

    _alertCompleteSubscription =
        _alertService.onAlertComplete.first.asStream().listen((_) {
      _alertDismissTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted && _showAlert) {
          setState(() => _showAlert = false);
        }
      });
    });
  }

  void _cancelAlertAutoDismiss() {
    _alertDismissTimer?.cancel();
    _alertCompleteSubscription?.cancel();
  }

  // ---------------------------------------------------------------------------
  // Google Maps helpers
  // ---------------------------------------------------------------------------

  /// Build the Set<Marker> for Google Maps from the current POI list.
  Set<Marker> _buildGoogleMarkers() {
    final Set<Marker> markers = _pois.map((poi) {
      final double hue = _getMarkerHue(poi.type);
      final double? distance = _distances[poi.id];
      final bool approaching = _approachingStatus[poi.id] ?? false;
      final String dirLabel = _hasReliableHeading
          ? (approaching ? ' · APPROACHING' : ' · MOVING AWAY')
          : '';
      final String snippet = distance != null
          ? '${_locationService.formatDistance(distance)}$dirLabel'
          : poi.description;

      return Marker(
        markerId: MarkerId(poi.id),
        position: LatLng(poi.latitude, poi.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(hue),
        infoWindow: InfoWindow(
          title: poi.name,
          snippet: snippet,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => POIDetailsScreen(poi: poi)),
            );
          },
        ),
        onTap: () {
          // Show info window on tap (default behaviour)
        },
      );
    }).toSet();

    return markers;
  }

  /// Map POI type to a Google Maps marker hue.
  double _getMarkerHue(String type) {
    switch (type) {
      case 'yellow_box':
      case 'danger':
        return BitmapDescriptor.hueRed;
      case 'school_street':
      case 'ltn':
      case 'caution':
        return BitmapDescriptor.hueOrange;
      case 'no_entry':
      case 'restricted_route':
        return BitmapDescriptor.hueRose;
      case 'pedestrian_zone':
        return BitmapDescriptor.hueViolet;
      default:
        return BitmapDescriptor.hueAzure;
    }
  }

  /// Draw a navigation arrow icon on a Canvas and convert to BitmapDescriptor.
  /// Called once at startup; the Marker's `rotation` handles heading changes.
  /*Future<void> _createNavArrowIcon() async {
    const double size = 80;
    const double arrowPadding = 12;

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final double center = size / 2;

    // Outer glow / shadow circle
    canvas.drawCircle(
      Offset(center, center),
      center - 2,
      Paint()
        ..color = Colors.blue.withOpacity(0.15)
        ..style = PaintingStyle.fill,
    );

    // Blue filled circle background
    canvas.drawCircle(
      Offset(center, center),
      center - arrowPadding,
      Paint()
        ..color = const Color(0xFF1A73E8)
        ..style = PaintingStyle.fill,
    );

    // White border ring
    canvas.drawCircle(
      Offset(center, center),
      center - arrowPadding,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    // White arrow pointing UP (triangle)
    final Path arrow = Path()
      ..moveTo(center, arrowPadding + 6) // top tip
      ..lineTo(center + 12, size - arrowPadding - 8) // bottom right
      ..lineTo(center, size - arrowPadding - 14) // inner notch
      ..lineTo(center - 12, size - arrowPadding - 8) // bottom left
      ..close();

    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );

    final ui.Image image = await recorder
        .endRecording()
        .toImage(size.toInt(), size.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);

    if (data != null && mounted) {
      setState(() {
        _navArrowIcon = BitmapDescriptor.bytes(data.buffer.asUint8List());
      });
    }
  }*/

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  void _showLocationServiceDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Location Services Disabled'),
        content: const Text(
          'Please enable location services in your device settings to use this app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Location Permission Required'),
        content: const Text(
          'This app needs location permission to alert you when approaching dangerous areas. Please grant permission in app settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Geolocator.openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _recenterCamera() async {
    _autoRecenterTimer?.cancel();
    Position? pos =
        _currentPosition ?? await _locationService.getCurrentPosition();
    if (!mounted) return;
    setState(() {
      _isAutoFollow = true;
      if (pos != null) _currentPosition = pos;
    });
    if (pos != null && _mapController != null) {
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(pos.latitude, pos.longitude),
            zoom: _autoFollowZoom,
            bearing: _hasReliableHeading ? _userHeading : 0.0,
            tilt: _autoFollowTilt,
          ),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: const [
            Icon(Icons.map, size: 24),
            SizedBox(width: 8),
            Text('RoadVigil'),
          ],
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          if (_locationPermissionGranted)
            IconButton(
              icon: Icon(
                _isAutoFollow ? Icons.my_location : Icons.location_searching,
              ),
              tooltip: _isAutoFollow ? 'Following' : 'Re-center',
              onPressed: _recenterCamera,
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              // Reload alert distance in case user changed it
              await _loadAlertDistance();
            },
          ),
        ],
      ),
      body: _isLoading
          ? _buildLoadingScreen()
          : !_locationPermissionGranted
              ? _buildPermissionRequiredScreen()
              : _buildMapScreen(),
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-widgets
  // ---------------------------------------------------------------------------

  Widget _buildLoadingScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: AppColors.primary),
          const SizedBox(height: 24),
          Text(
            _statusMessage,
            style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionRequiredScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_off, size: 100, color: Colors.grey.shade400),
            const SizedBox(height: 24),
            Text(
              'Location Permission Required',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              _statusMessage,
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _checkLocationAndStartTracking,
              icon: const Icon(Icons.refresh),
              label: const Text('Grant Permission'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapScreen() {
    final double centerLat =
        _currentPosition?.latitude ?? LondonPOIs.centerLatitude;
    final double centerLng =
        _currentPosition?.longitude ?? LondonPOIs.centerLongitude;

    return Stack(
      children: [
        // --- Google Map with human drag detection ---
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerMove: (PointerMoveEvent event) {
            // Require a deliberate swipe gesture (> 12 pixels) to pause auto-follow
            if (event.delta.distance > 12) {
              if (_isAutoFollow) {
                setState(() => _isAutoFollow = false);
              }
              // Auto-recenter after 6 seconds of inactivity (like Google Maps)
              _autoRecenterTimer?.cancel();
              _autoRecenterTimer = Timer(const Duration(seconds: 6), () {
                if (mounted) _recenterCamera();
              });
            }
          },
          child: GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(centerLat, centerLng),
              zoom: _autoFollowZoom,
              tilt: _autoFollowTilt,
            ),
            buildingsEnabled: false,
            onMapCreated: (GoogleMapController controller) {
              _mapController = controller;
              if (_currentPosition != null && _isAutoFollow) {
                controller.animateCamera(
                  CameraUpdate.newCameraPosition(
                    CameraPosition(
                      target: LatLng(
                        _currentPosition!.latitude,
                        _currentPosition!.longitude,
                      ),
                      zoom: _autoFollowZoom,
                      bearing: _hasReliableHeading ? _userHeading : 0.0,
                      tilt: _autoFollowTilt,
                    ),
                  ),
                );
              }
            },
            markers: _buildGoogleMarkers(),
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            trafficEnabled: true,
            mapType: MapType.normal,
            zoomControlsEnabled: false,
            compassEnabled: true,
            mapToolbarEnabled: false,
            minMaxZoomPreference: const MinMaxZoomPreference(10.0, 20.0),
          ),
        ),
        // --- Overlays (on top of the map) ---
        if (kShowDebugOverlay) _buildDebugOverlay(),
        _buildPOIList(),

        // --- Prominent floating Re-center button when in free-roam mode ---
        if (!_isAutoFollow)
          Positioned(
            bottom: _pois.isEmpty ? 70 : 100,
            right: 16,
            child: FloatingActionButton.extended(
              onPressed: _recenterCamera,
              backgroundColor: AppColors.primary,
              icon: const Icon(Icons.navigation, color: Colors.white, size: 20),
              label: const Text(
                'Re-center',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Overlay widgets
  // ---------------------------------------------------------------------------

  Color _getColorForType(String type) {
    switch (type) {
      case 'yellow_box':
      case 'danger':
        return AppColors.danger;
      case 'school_street':
      case 'ltn':
      case 'caution':
        return AppColors.warning;
      default:
        return AppColors.info;
    }
  }

  Widget _buildTrackingBanner() {
    final bool connected = _supabaseConnected;
    final Color bannerColor =
        connected ? AppColors.success : AppColors.warning;
    final String label = "";

    return Positioned(
      top: 16,
      left: 16,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bannerColor,
          borderRadius: BorderRadius.circular(25),
          boxShadow: [
            BoxShadow(
              color: bannerColor.withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Debug overlay (temporary — gated by kShowDebugOverlay)
  // ---------------------------------------------------------------------------

  Widget _buildDebugOverlay() {
    // Find nearest POI from the cached list
    String nearestName = '—';
    double? nearestDist;
    int inRangeCount = 0;

    if (_pois.isNotEmpty && _distances.isNotEmpty) {
      String? nearestId;
      for (final entry in _distances.entries) {
        if (nearestDist == null || entry.value < nearestDist!) {
          nearestDist = entry.value;
          nearestId = entry.key;
        }
        if (entry.value <= _alertDistance) inRangeCount++;
      }
      if (nearestId != null) {
        final poi = _pois.firstWhere(
          (p) => p.id == nearestId,
          orElse: () => _pois.first,
        );
        nearestName = poi.name;
      }
    }

    // Heading & approach info for nearest POI
    String nearestApproach = '';
    if (_hasReliableHeading && _pois.isNotEmpty && _distances.isNotEmpty) {
      final nearId = _distances.entries
          .reduce((a, b) => a.value < b.value ? a : b)
          .key;
      final bool approaching = _approachingStatus[nearId] ?? false;
      nearestApproach = approaching ? ' → APPROACHING' : ' → AWAY';
    }

    final double? accuracy = _currentPosition?.accuracy;
    final String distStr =
        nearestDist != null ? nearestDist.toStringAsFixed(1) : '—';
    final String accStr =
        accuracy != null ? '±${accuracy.toStringAsFixed(1)}m' : '—';

    // Confidence label for the current GPS tick
    String confidenceLabel = '';
    if (!_lastTickAccepted && _lastTickWasFallback) {
      confidenceLabel = ' (LOW - fallback)';
    } else if (!_lastTickAccepted) {
      confidenceLabel = ' (LOW - ignored)';
    }

    final Color bgColor = _debugAlertFlash
        ? Colors.red.withOpacity(0.85)
        : _lastTickWasFallback
            ? Colors.orange.withOpacity(0.80)
            : !_lastTickAccepted
                ? Colors.amber.shade800.withOpacity(0.75)
                : Colors.black.withOpacity(0.55);

    return Positioned(
      top: 56,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$nearestName | dist: ${distStr}m | acc: $accStr$confidenceLabel | trigger: ${_alertDistance}m'
            '${_hasReliableHeading ? ' | hdg: ${_userHeading.toStringAsFixed(0)}°$nearestApproach' : ''}'
            '${inRangeCount > 0 ? ' | ($inRangeCount in range)' : ''}',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              fontFamily: 'monospace',
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  Widget _buildPOIList() {
    if (_pois.isEmpty) {
      // Sleek minimal floating pill when no restrictions nearby
      return Positioned(
        bottom: 16,
        left: 20,
        right: 20,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                color: AppColors.success,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _supabaseConnected
                      ? 'No restrictions nearby'
                      : 'Connecting to database...',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.success.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'All Clear',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.success,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Compact horizontal scrolling card strip when restrictions are present
    return Positioned(
      bottom: 12,
      left: 0,
      right: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 14, color: AppColors.danger),
                      const SizedBox(width: 4),
                      Text(
                        '${_pois.length} Restrictions Ahead',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: AppColors.danger,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 64,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _pois.length,
              itemBuilder: (context, index) {
                return _buildPOICard(_pois[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPOICard(POI poi) {
    Color cardColor = _getColorForType(poi.type);
    bool isActive = _currentAlertPOI?.id == poi.id && _showAlert;
    double? distance = _distances[poi.id];
    String distanceText = distance != null
        ? _locationService.formatDistance(distance)
        : '...';
    final bool approaching = _approachingStatus[poi.id] ?? false;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => POIDetailsScreen(poi: poi)),
        );
      },
      child: Container(
        width: 200,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? cardColor.withOpacity(0.15) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cardColor.withOpacity(isActive ? 0.9 : 0.4),
            width: isActive ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: cardColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.warning, color: cardColor, size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    poi.name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        distanceText,
                        style: TextStyle(
                          fontSize: 11,
                          color: cardColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (_hasReliableHeading) ...[
                        const SizedBox(width: 6),
                        Icon(
                          approaching
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                          size: 10,
                          color: approaching
                              ? AppColors.danger
                              : AppColors.success,
                        ),
                        Text(
                          approaching ? 'NEAR' : 'AWAY',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: approaching
                                ? AppColors.danger
                                : AppColors.success,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertOverlay(POI poi) {
    double? distance = _distances[poi.id];
    String distanceText = distance != null
        ? _locationService.formatDistance(distance)
        : 'Unknown';
    final bool approaching = _approachingStatus[poi.id] ?? false;

    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _showAlert = false),
        child: Container(
          color: Colors.black.withOpacity(0.8),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                margin: const EdgeInsets.all(32),
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 20,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.warning_amber_rounded,
                        size: 70,
                        color: AppColors.danger,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'PROXIMITY ALERT!',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: AppColors.danger,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      poi.alertMessage,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.6,
                        color: AppColors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    // Direction badge
                    if (_hasReliableHeading)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: approaching
                              ? AppColors.danger.withOpacity(0.1)
                              : AppColors.success.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: approaching
                                ? AppColors.danger
                                : AppColors.success,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              approaching
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              size: 16,
                              color: approaching
                                  ? AppColors.danger
                                  : AppColors.success,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              approaching ? 'APPROACHING' : 'MOVING AWAY',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: approaching
                                    ? AppColors.danger
                                    : AppColors.success,
                              ),
                            ),
                          ],
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.social_distance,
                            size: 18,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Distance: $distanceText',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              _cancelAlertAutoDismiss();
                              setState(() => _showAlert = false);
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.textSecondary,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 16),
                              side: BorderSide(
                                  color: Colors.grey.shade300, width: 2),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'Dismiss',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: () {
                              _cancelAlertAutoDismiss(); // cancel before navigating
                              setState(() => _showAlert = false);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      POIDetailsScreen(poi: poi),
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 16),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'View Details',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}