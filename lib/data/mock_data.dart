import '../models/poi_model.dart';

class MockData {
  static List<POI> getSamplePOIs() {
    return [
      POI(
        id: '1',
        name: 'Construction Zone',
        description: 'Major road construction ahead',
        latitude: 37.7749,
        longitude: -122.4194,
        type: 'construction',
        alertMessage: '⚠️ Construction Zone 150m ahead - Expect delays',
        alertDistance: 150,
      ),
      POI(
        id: '2',
        name: 'Accident Prone Area',
        description: 'High accident rate zone',
        latitude: 37.7849,
        longitude: -122.4094,
        type: 'danger',
        alertMessage: '🚨 Danger Zone Ahead - Drive Carefully',
        alertDistance: 200,
      ),
      POI(
        id: '3',
        name: 'School Zone',
        description: 'Reduced speed limit',
        latitude: 37.7649,
        longitude: -122.4294,
        type: 'caution',
        alertMessage: '🏫 School Zone - Reduce Speed',
        alertDistance: 100,
      ),
      POI(
        id: '4',
        name: 'Flood Area',
        description: 'Potential flooding during rain',
        latitude: 37.7549,
        longitude: -122.4394,
        type: 'warning',
        alertMessage: '💧 Flood Prone Area - Use Alternative Route',
        alertDistance: 200,
      ),
    ];
  }
}