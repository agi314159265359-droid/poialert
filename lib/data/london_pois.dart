import '../models/poi_model.dart';

/// Offline / demo fallback data.
/// The full dataset is fetched live from Supabase; this is only used when:
///   - the database is unreachable (offline mode), or
///   - Demo Mode is triggered before the first successful query.
class LondonPOIs {
  /// Central London default map centre.
  static const double centerLatitude = 51.509;
  static const double centerLongitude = -0.118;

  /// Single hardcoded demo POI used when Supabase is not available.
  static const POI demoFallback = POI(
    id: 'demo-offline-1',
    name: 'Yellow Box Junction',
    description: 'Demo: offline fallback POI',
    latitude: 51.408584,
    longitude: -0.161731,
    type: 'yellow_box',
    alertMessage: '⚠️ DEMO: Yellow box junction ahead. Do not enter unless your exit is clear.',
    alertDistance: 150,
  );
}