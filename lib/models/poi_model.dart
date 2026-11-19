class POI {
  final String id;
  final String name;
  final String description;
  final double latitude;
  final double longitude;
  final String type; // yellow_box, no_entry, no_right_turn, no_left_turn, no_u_turn,
                      // school_street, ltn, restricted_route, pedestrian_zone, other, unknown
  final String alertMessage;
  final int alertDistance; // in meters

  // Extra fields from Supabase (nullable for backwards compatibility)
  final String? council;
  final String? street;
  final String? adjoiningStreet;
  final String? schoolName;

  const POI({
    required this.id,
    required this.name,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.type,
    required this.alertMessage,
    this.alertDistance = 150,
    this.council,
    this.street,
    this.adjoiningStreet,
    this.schoolName,
  });

  /// Construct a POI from a row returned by the nearby_pois Supabase RPC.
  factory POI.fromSupabaseRow(Map<String, dynamic> row) {
    final String type = (row['type'] as String?) ?? 'unknown';
    final String street = (row['street'] as String?) ?? '';
    final String name = (row['name'] as String?) ?? street;

    return POI(
      id: (row['id'] as String?) ?? '',
      name: name.isNotEmpty ? name : 'Traffic Restriction',
      description: '$type${street.isNotEmpty ? ' — $street' : ''}',
      latitude: (row['lat'] as num).toDouble(),
      longitude: (row['lng'] as num).toDouble(),
      type: type,
      alertMessage: (row['alert_message'] as String?) ??
          '⚠️ Traffic restriction ahead',
      alertDistance: 150, // default; controlled per-query by the repository
      council: row['council'] as String?,
      street: street.isNotEmpty ? street : null,
      adjoiningStreet: row['adjoining_street'] as String?,
      schoolName: row['school_name'] as String?,
    );
  }
}