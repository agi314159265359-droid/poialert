import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/poi_model.dart';

/// Repository that fetches nearby Points of Interest from Supabase
/// via the `nearby_pois` Postgres RPC function.
class PoiRepository {
  static final PoiRepository _instance = PoiRepository._internal();
  factory PoiRepository() => _instance;
  PoiRepository._internal();

  final SupabaseClient _client = Supabase.instance.client;

  /// Fetches POIs within [radiusMeters] of the given coordinates.
  ///
  /// Returns an empty list (never throws) so callers can safely use the result
  /// even without internet / when Supabase is unreachable.
  Future<List<POI>> getNearbyPois(
    double lat,
    double lng, {
    int radiusMeters = 1000,
  }) async {
    try {
      final response = await _client.rpc(
        'nearby_pois',
        params: {
          'user_lat': lat,
          'user_lng': lng,
          'radius_meters': radiusMeters,
        },
      );

      if (response == null) {
        print('[PoiRepository] RPC returned null');
        return [];
      }

      final List<dynamic> rows = response as List<dynamic>;
      final pois = rows
          .map((row) => POI.fromSupabaseRow(row as Map<String, dynamic>))
          .toList();

      print('[PoiRepository] fetched ${pois.length} POIs '
          '(radius: ${radiusMeters}m, lat: $lat, lng: $lng)');
      return pois;
    } on PostgrestException catch (e) {
      print('[PoiRepository] Supabase error: ${e.message}');
      return [];
    } catch (e) {
      print('[PoiRepository] Unexpected error: $e');
      return [];
    }
  }
}
