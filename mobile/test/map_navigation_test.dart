import 'package:flutter_test/flutter_test.dart';
import 'package:rcmca_mobile/main.dart';
import 'package:rcmca_mobile/navigation_controller.dart';

void main() {
  group('Hazard Status Color Tests', () {
    test('Config provides all 5 status colors and exact hex values', () {
      expect(HazardStatusConfig.green.hex, '#22C55E');
      expect(HazardStatusConfig.green.label, 'Registered');

      expect(HazardStatusConfig.blue.hex, '#3B82F6');
      expect(HazardStatusConfig.blue.label, 'Resolved');

      expect(HazardStatusConfig.yellow.hex, '#EAB308');
      expect(HazardStatusConfig.yellow.label, 'Still Active');

      expect(HazardStatusConfig.orange.hex, '#F97316');
      expect(HazardStatusConfig.orange.label, 'Impacting Others');

      expect(HazardStatusConfig.red.hex, '#EF4444');
      expect(HazardStatusConfig.red.label, 'Ecosystem/Environment');
    });

    test('RoadHazard parses status_color from JSON', () {
      final hazardGreen = RoadHazard.fromJson({
        'id': 'h-1',
        'category': 'pothole',
        'severity': 2,
        'description': 'Minor surface indentation',
        'latitude': 17.4400,
        'longitude': 78.3480,
        'status': 'community_pending',
        'status_color': 'GREEN',
      });
      expect(hazardGreen.statusColor, 'GREEN');
      expect(hazardGreen.statusHexColor, '#22C55E');
      expect(hazardGreen.statusTitle, 'Registered');

      final hazardBlue = RoadHazard.fromJson({
        'id': 'h-2',
        'category': 'pothole',
        'severity': 3,
        'description': 'Repaired asphalt patch',
        'latitude': 17.4270,
        'longitude': 78.5320,
        'status': 'resolved',
        'status_color': 'BLUE',
      });
      expect(hazardBlue.statusColor, 'BLUE');
      expect(hazardBlue.statusHexColor, '#3B82F6');
      expect(hazardBlue.statusTitle, 'Resolved');

      final hazardYellow = RoadHazard.fromJson({
        'id': 'h-3',
        'category': 'damaged_surface',
        'severity': 2,
        'description': 'Rough road',
        'latitude': 17.4120,
        'longitude': 78.4600,
        'status': 'active_hazard',
        'status_color': 'YELLOW',
      });
      expect(hazardYellow.statusColor, 'YELLOW');
      expect(hazardYellow.statusHexColor, '#EAB308');
      expect(hazardYellow.statusTitle, 'Still Active');

      final hazardOrange = RoadHazard.fromJson({
        'id': 'h-4',
        'category': 'open_manhole',
        'severity': 4,
        'description': 'Dangerous open pit',
        'latitude': 17.4560,
        'longitude': 78.4440,
        'status': 'active_hazard',
        'status_color': 'ORANGE',
      });
      expect(hazardOrange.statusColor, 'ORANGE');
      expect(hazardOrange.statusHexColor, '#F97316');
      expect(hazardOrange.statusTitle, 'Impacting Others');

      final hazardRed = RoadHazard.fromJson({
        'id': 'h-5',
        'category': 'waterlogging',
        'severity': 3,
        'description': 'Overflowing nala and sewage across lanes',
        'latitude': 17.3600,
        'longitude': 78.4740,
        'status': 'active_hazard',
        'status_color': 'RED',
      });
      expect(hazardRed.statusColor, 'RED');
      expect(hazardRed.statusHexColor, '#EF4444');
      expect(hazardRed.statusTitle, 'Ecosystem/Environment');
    });
  });

  group('NavigationController and Route Activation Callback Tests', () {
    test('activateRecommendedRoute switches tab to 0 and invokes route callback', () async {
      int? switchedToTab;
      Map<String, dynamic>? receivedPayload;
      bool? startedDriveway;

      NavigationController.instance.switchTab = (int index) {
        switchedToTab = index;
      };

      NavigationController.instance.onActivateRecommendedRoute =
          (Map<String, dynamic> payload, {bool startDriveway = true}) async {
        receivedPayload = payload;
        startedDriveway = startDriveway;
      };

      final samplePayload = {
        'origin_name': 'Gachibowli',
        'destination_name': 'Tarnaka',
        'geometry': {
          'coordinates': [
            [78.3480, 17.4400],
            [78.5320, 17.4270],
          ],
        },
      };

      // Call top-level function
      await activateRecommendedRoute(samplePayload);

      expect(switchedToTab, 0);
      expect(receivedPayload, samplePayload);
      expect(startedDriveway, isTrue);
      expect(NavigationController.instance.lastRoutePayload, samplePayload);
    });
  });
}
