import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'navigation_controller.dart';
import 'screens/chat_screen.dart';
import 'widgets/issue_detail_sheet.dart';
import 'widgets/survey_sheets.dart';

export 'navigation_controller.dart';

const apiBase = String.fromEnvironment(
  'RCMCA_API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8001',
);
const hyderabad = LatLng(17.3850, 78.4867);

/// Request high-accuracy GPS fix from device hardware.
Future<Position> requestCurrentPosition(LocationAccuracy accuracy) async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw Exception('Turn on device location and try again.');
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw Exception(
        'Location permission is needed for road reports and navigation.');
  }
  return Geolocator.getCurrentPosition(
    locationSettings:
        LocationSettings(accuracy: accuracy, timeLimit: const Duration(seconds: 12)),
  );
}

void main() => runApp(const RcmcaApp());

/// Root app widget managing the top-level tab navigation shell.
class RcmcaApp extends StatefulWidget {
  const RcmcaApp({super.key});

  @override
  State<RcmcaApp> createState() => _RcmcaAppState();
}

class _RcmcaAppState extends State<RcmcaApp> {
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    // Connect top-level navigation controller to allow switching directly to Map tab.
    NavigationController.instance.switchTab = (int index) {
      if (mounted) {
        setState(() => _currentTab = index);
      }
    };
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RCMCA',
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF00838F), // Cyan/Teal civic theme
          useMaterial3: true,
        ),
        home: Scaffold(
          body: IndexedStack(
            index: _currentTab,
            children: [
              const RoadMapScreen(),
              ChatScreen(
                showAppBar: false,
                onStartDriveway: (ChatRoutePlan plan) async {
                  await activateRecommendedRoute({
                    'route_id': plan.routeId,
                    'label': plan.label,
                    'distance_m': plan.distanceKm * 1000.0,
                    'duration_s': plan.durationMin * 60.0,
                    'geometry': plan.geometry,
                    'hazards': plan.issuesOnRoute,
                  });
                },
              ),
              const CaptureScreen(),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _currentTab,
            onDestinationSelected: (int index) {
              setState(() => _currentTab = index);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.map_outlined),
                selectedIcon: Icon(Icons.map),
                label: 'Map',
              ),
              NavigationDestination(
                icon: Icon(Icons.smart_toy_outlined),
                selectedIcon: Icon(Icons.smart_toy),
                label: 'Chatbot',
              ),
              NavigationDestination(
                icon: Icon(Icons.camera_alt_outlined),
                selectedIcon: Icon(Icons.camera_alt),
                label: 'Report',
              ),
            ],
          ),
        ),
      );
}

/// Known Hyderabad localities dictionary for offline fallback place name resolution.
const Map<String, LatLng> _hyderabadLocalities = {
  'gachibowli': LatLng(17.4400, 78.3480),
  'tarnaka': LatLng(17.4270, 78.5320),
  'hitec city': LatLng(17.4435, 78.3772),
  'hitech city': LatLng(17.4435, 78.3772),
  'madhapur': LatLng(17.4480, 78.3910),
  'kondapur': LatLng(17.4690, 78.3640),
  'banjara hills': LatLng(17.4126, 78.4482),
  'jubilee hills': LatLng(17.4319, 78.4073),
  'khairatabad': LatLng(17.4120, 78.4600),
  'sanathnagar': LatLng(17.4560, 78.4440),
  'secunderabad': LatLng(17.4399, 78.4983),
  'charminar': LatLng(17.3616, 78.4747),
  'pathergatti': LatLng(17.3600, 78.4740),
  'begumpet': LatLng(17.4447, 78.4664),
  'ameerpet': LatLng(17.4375, 78.4482),
  'kphb': LatLng(17.4930, 78.3990),
  'kphb colony': LatLng(17.4930, 78.3990),
  'kukatpally': LatLng(17.4849, 78.4138),
  'jeedimetla': LatLng(17.5110, 78.4400),
  'malkajgiri': LatLng(17.4560, 78.5270),
  'ramanthapur': LatLng(17.3990, 78.5410),
  'uppal': LatLng(17.4022, 78.5602),
  'vanasthalipuram': LatLng(17.3300, 78.5720),
  'lb nagar': LatLng(17.3457, 78.5522),
  'kapra': LatLng(17.4780, 78.5640),
  'mehdipatnam': LatLng(17.3916, 78.4398),
  'panjagutta': LatLng(17.4265, 78.4533),
  'abids': LatLng(17.3910, 78.4735),
  'dilsukhnagar': LatLng(17.3688, 78.5247),
  'nanakramguda': LatLng(17.4156, 78.3428),
  'miyapur': LatLng(17.4969, 78.3546),
  'lingampally': LatLng(17.4834, 78.3158),
  'somajiguda': LatLng(17.4260, 78.4608),
  'alwal': LatLng(17.5020, 78.5080),
  'bowenpally': LatLng(17.4760, 78.4830),
  'shamshabad': LatLng(17.2403, 78.4294),
  'hyderabad': LatLng(17.3850, 78.4867),
};

/// 5-color status definitions for hazard pins on MapLibre:
/// GREEN (#22C55E Registered), BLUE (#3B82F6 Resolved), YELLOW (#EAB308 Still Active),
/// ORANGE (#F97316 Impacting Others), RED (#EF4444 Ecosystem/Environment).
class HazardStatusConfig {
  const HazardStatusConfig({
    required this.key,
    required this.hex,
    required this.color,
    required this.label,
    required this.description,
  });

  final String key;
  final String hex;
  final Color color;
  final String label;
  final String description;

  static const green = HazardStatusConfig(
    key: 'GREEN',
    hex: '#22C55E',
    color: Color(0xFF22C55E),
    label: 'Registered',
    description: 'Newly registered civic issue',
  );

  static const blue = HazardStatusConfig(
    key: 'BLUE',
    hex: '#3B82F6',
    color: Color(0xFF3B82F6),
    label: 'Resolved',
    description: 'Confirmed resolved or closed',
  );

  static const yellow = HazardStatusConfig(
    key: 'YELLOW',
    hex: '#EAB308',
    color: Color(0xFFEAB308),
    label: 'Still Active',
    description: 'Ongoing active hazard',
  );

  static const orange = HazardStatusConfig(
    key: 'ORANGE',
    hex: '#F97316',
    color: Color(0xFFF97316),
    label: 'Impacting Others',
    description: 'Severe impact or multiple reports',
  );

  static const red = HazardStatusConfig(
    key: 'RED',
    hex: '#EF4444',
    color: Color(0xFFEF4444),
    label: 'Ecosystem/Environment',
    description: 'Sewage, nala, or ecological risk',
  );

  static const List<HazardStatusConfig> all = [
    green,
    blue,
    yellow,
    orange,
    red,
  ];

  static HazardStatusConfig fromKey(String? key) {
    if (key == null) return green;
    final upper = key.toUpperCase();
    for (final cfg in all) {
      if (cfg.key == upper) return cfg;
    }
    return green;
  }
}

/// Road hazard data model supporting status_color categorization.
class RoadHazard {
  RoadHazard.fromJson(Map<String, dynamic> json)
      : rawJson = json,
        id = json['id'] as String,
        category = json['category'] as String,
        severity = (json['severity'] as num).toInt(),
        description = json['description'] as String,
        latitude = (json['latitude'] as num).toDouble(),
        longitude = (json['longitude'] as num).toDouble(),
        status = json['status'] as String,
        statusColor = _resolveStatusColor(
          json['status_color'] as String?,
          json['status'] as String?,
          (json['severity'] as num).toInt(),
          json['description'] as String?,
          json['impact_mcq'] as String?,
        );

  final Map<String, dynamic> rawJson;
  final String id;
  final String category;
  final int severity;
  final String description;
  final double latitude;
  final double longitude;
  final String status;
  final String statusColor;

  static String _resolveStatusColor(
    String? color,
    String? status,
    int severity,
    String? desc,
    String? impact,
  ) {
    if (color != null && color.isNotEmpty) {
      final upper = color.toUpperCase();
      if (upper == 'GREEN' ||
          upper == 'BLUE' ||
          upper == 'YELLOW' ||
          upper == 'ORANGE' ||
          upper == 'RED') {
        return upper;
      }
    }
    if (status == 'resolved') return 'BLUE';
    final descLower = (desc ?? '').toLowerCase();
    final impactLower = (impact ?? '').toLowerCase();
    if (descLower.contains('ecosystem') ||
        descLower.contains('sewage') ||
        descLower.contains('sewer') ||
        descLower.contains('nala') ||
        impactLower.contains('ecosystem') ||
        impactLower.contains('sewage') ||
        impactLower.contains('sewer') ||
        impactLower.contains('nala')) {
      return 'RED';
    }
    if (severity >= 4) return 'ORANGE';
    if (status == 'active_hazard' || status == 'verified_ghmc') return 'YELLOW';
    return 'GREEN';
  }

  HazardStatusConfig get config => HazardStatusConfig.fromKey(statusColor);
  String get statusHexColor => config.hex;
  String get statusTitle => config.label;
}

/// MapLibre map screen with 5-color hazard pins, A→B place name route planner,
/// dashed gray rejected routes, bold cyan/teal recommended route, and in-app driveway mode.
class RoadMapScreen extends StatefulWidget {
  const RoadMapScreen({super.key});

  @override
  State<RoadMapScreen> createState() => RoadMapScreenState();
}

class RoadMapScreenState extends State<RoadMapScreen> {
  MapLibreMapController? _map;
  StreamSubscription<Position>? _positionSubscription;
  Position? _position;
  List<RoadHazard> _hazards = [];
  final Map<String, RoadHazard> _symbolHazardMap = {};
  List<Symbol> _symbols = [];

  // Routing lines
  Line? _recommendedRouteLine;
  final List<Line> _rejectedRouteLines = [];
  List<LatLng> _recommendedCoordinates = [];
  List<List<LatLng>> _rejectedGeometries = [];

  String? _error;
  bool _navigationActive = false;
  bool _loadingHazards = false;
  bool _isPlanningRoute = false;
  bool _reloadHazardsAfterCurrent = false;
  bool _forceHazardReloadAfterCurrent = false;
  DateTime? _lastHazardRefreshAt;
  final Set<String> _promptedIssueIds = {};
  String? _userId;

  // A→B Place Name Controllers (Accepts place names e.g., "Gachibowli" to "Tarnaka")
  final TextEditingController _originController =
      TextEditingController(text: 'Gachibowli');
  final TextEditingController _destinationController =
      TextEditingController(text: 'Tarnaka');

  // In-App Driveway State
  bool _drivewayActive = false;
  bool _drivewayPaused = false;
  bool _drivewayCompleted = false;
  Timer? _drivewayTimer;
  List<LatLng> _drivewayWaypoints = [];
  int _drivewayIndex = 0;
  double _drivewayProgress = 0.0;
  double _drivewayRemainingMeters = 0.0;
  int _drivewayEtaMinutes = 0;
  RoadHazard? _drivewayNearbyHazard;
  Symbol? _drivewayVehicleSymbol;

  // Staged payload in case activateRecommendedRoute is called before map style loads
  Map<String, dynamic>? _pendingRoutePayload;

  @override
  void initState() {
    super.initState();
    _loadAnonymousUserId();

    // Register callback for Chatbot tab and external callers
    NavigationController.instance.onActivateRecommendedRoute =
        (payload, {bool startDriveway = true}) async {
      await activateRecommendedRoute(payload, startDriveway: startDriveway);
    };

    // If a payload was queued before mounting, stage it
    if (NavigationController.instance.lastRoutePayload != null) {
      _pendingRoutePayload = NavigationController.instance.lastRoutePayload;
    }
  }

  Future<void> _loadAnonymousUserId() async {
    final preferences = await SharedPreferences.getInstance();
    final id = preferences.getString('rcmca_anonymous_user_id') ?? const Uuid().v4();
    await preferences.setString('rcmca_anonymous_user_id', id);
    if (mounted) setState(() => _userId = id);
  }

  @override
  void dispose() {
    _drivewayTimer?.cancel();
    _positionSubscription?.cancel();
    _originController.dispose();
    _destinationController.dispose();
    if (NavigationController.instance.onActivateRecommendedRoute != null) {
      NavigationController.instance.onActivateRecommendedRoute = null;
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Geolocation & Hazard Streaming
  // ---------------------------------------------------------------------------

  Future<void> _startLocation() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) throw Exception('Turn on device location to use road alerts.');
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception(
            'Location permission is needed for reports and nearby alerts.');
      }

      final settings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
              foregroundNotificationConfig: _navigationActive
                  ? const ForegroundNotificationConfig(
                      notificationTitle: 'RCMCA navigation is active',
                      notificationText:
                          'Checking nearby road hazards while you travel.',
                      enableWakeLock: false,
                      setOngoing: true,
                    )
                  : null,
            )
          : AppleSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
              activityType: ActivityType.automotiveNavigation,
              allowBackgroundLocationUpdates: _navigationActive,
              pauseLocationUpdatesAutomatically: true,
            );

      _positionSubscription?.cancel();
      _positionSubscription =
          Geolocator.getPositionStream(locationSettings: settings).listen(
        (position) {
          if (!mounted) return;
          setState(() => _position = position);
          if (_map != null) _loadHazards();
          if (_navigationActive && !_drivewayActive) {
            _checkNearbyHazards(position);
          }
        },
        onError: (Object error) {
          if (mounted) setState(() => _error = 'Location stream failed: $error');
        },
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> _onMapCreated(MapLibreMapController controller) async {
    _map = controller;
    controller.onSymbolTapped.add((symbol) {
      final hazard = _symbolHazardMap[symbol.id];
      if (hazard != null && mounted) {
        showIssueDetailSheet(
          context,
          issue: hazard.rawJson,
        ).then((_) => _loadHazards(force: true));
      }
    });
  }

  Future<void> _onStyleLoaded() async {
    await _loadHazards();
    if (_pendingRoutePayload != null) {
      final payload = _pendingRoutePayload!;
      _pendingRoutePayload = null;
      await activateRecommendedRoute(payload, startDriveway: true);
    }
  }

  // ---------------------------------------------------------------------------
  // 1. Color-coded Hazard Pins & 5-Color Legend
  // ---------------------------------------------------------------------------

  Future<void> _loadHazards({bool force = false}) async {
    final map = _map;
    if (map == null) return;
    if (_loadingHazards) {
      _reloadHazardsAfterCurrent = true;
      _forceHazardReloadAfterCurrent |= force;
      return;
    }
    final lastRefresh = _lastHazardRefreshAt;
    if (!force &&
        lastRefresh != null &&
        DateTime.now().difference(lastRefresh) < const Duration(seconds: 15)) {
      return;
    }
    _loadingHazards = true;
    try {
      final visibleBounds = await map.getVisibleRegion();
      final position = _position;
      final bounds = _navigationActive && position != null
          ? LatLngBounds(
              southwest:
                  LatLng(position.latitude - 0.012, position.longitude - 0.015),
              northeast:
                  LatLng(position.latitude + 0.012, position.longitude + 0.015),
            )
          : visibleBounds;

      final uri = Uri.parse('$apiBase/api/v1/issues').replace(queryParameters: {
        'south': bounds.southwest.latitude.toString(),
        'west': bounds.southwest.longitude.toString(),
        'north': bounds.northeast.latitude.toString(),
        'east': bounds.northeast.longitude.toString(),
        'limit': '500',
      });
      final response = await http.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw Exception('Hazard service returned ${response.statusCode}.');
      }

      final payload = (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
      final hazards = payload.map(RoadHazard.fromJson).toList();

      final old = _symbols;
      _symbols = [];
      _symbolHazardMap.clear();
      if (old.isNotEmpty) await map.removeSymbols(old);

      // Render pins color-coded by status_color:
      // GREEN (#22C55E), BLUE (#3B82F6), YELLOW (#EAB308), ORANGE (#F97316), RED (#EF4444)
      for (final hazard in hazards) {
        final symbol = await map.addSymbol(SymbolOptions(
          geometry: LatLng(hazard.latitude, hazard.longitude),
          iconImage: 'marker-15',
          iconColor: hazard.statusHexColor,
          iconSize: hazard.severity >= 4 ? 1.5 : 1.2,
          textField: '${hazard.category.replaceAll('_', ' ')} · ${hazard.statusTitle}',
          textOffset: const Offset(0, 1.2),
          textSize: 10.5,
          textColor: '#0F172A',
          textHaloColor: '#FFFFFF',
          textHaloWidth: 1.5,
        ));
        _symbols.add(symbol);
        _symbolHazardMap[symbol.id] = hazard;
      }

      _lastHazardRefreshAt = DateTime.now();
      if (mounted) {
        setState(() {
          _hazards = hazards;
          _error = null;
        });
      }
      if (_navigationActive && _position != null) {
        _checkNearbyHazards(_position!);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not load road hazards: $error');
      }
    } finally {
      _loadingHazards = false;
      if (mounted && _reloadHazardsAfterCurrent) {
        final reloadForce = _forceHazardReloadAfterCurrent;
        _reloadHazardsAfterCurrent = false;
        _forceHazardReloadAfterCurrent = false;
        unawaited(_loadHazards(force: reloadForce));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 2. Place Name Resolution (A → B) & Route Planning
  // ---------------------------------------------------------------------------

  Future<void> _planRoute() async {
    final map = _map;
    if (map == null) return;
    setState(() {
      _isPlanningRoute = true;
      _error = null;
    });

    try {
      final originText = _originController.text.trim();
      final destText = _destinationController.text.trim();

      dynamic originPayload = originText;
      dynamic destPayload = destText;

      // If user specified My Location / Current Location, grab live coordinates
      if (originText.toLowerCase() == 'my location' ||
          originText.toLowerCase() == 'current location') {
        final pos = _position ?? await requestCurrentPosition(LocationAccuracy.high);
        _position = pos;
        originPayload = {'latitude': pos.latitude, 'longitude': pos.longitude};
      }

      final response = await http.post(
        Uri.parse('$apiBase/api/v1/routes/plan'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'origin': originPayload,
          'destination': destPayload,
        }),
      ).timeout(const Duration(seconds: 25));

      if (response.statusCode != 200) {
        throw Exception('Route service returned ${response.statusCode}: ${response.body}');
      }

      final result = jsonDecode(response.body) as Map<String, dynamic>;
      result['origin_name'] = originText;
      result['destination_name'] = destText;

      await _applyRoutePayload(result, startDriveway: false);

      final distanceKm =
          ((result['distance_m'] as num?)?.toDouble() ?? 0.0) / 1000.0;
      final hazardsCount = (result['hazards'] as List?)?.length ?? 0;
      final avoided = result['avoided_severe_hazards'] == true
          ? ' · severe hazard avoided'
          : '';
      _message(
          '${distanceKm.toStringAsFixed(1)} km · $hazardsCount hazards on corridor$avoided');
    } catch (error) {
      if (mounted) {
        final msg = error.toString().replaceFirst('Exception: ', '');
        setState(() => _error = 'Could not plan route: $msg');
        _message('Route planning failed: $msg');
      }
    } finally {
      if (mounted) setState(() => _isPlanningRoute = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 3. Route Rendering (Bold Cyan/Teal Recommended + Dashed Gray Rejected)
  // ---------------------------------------------------------------------------

  List<LatLng> _parseCoordinatesList(dynamic raw) {
    if (raw == null) return [];
    final List<LatLng> coords = [];
    if (raw is List) {
      for (final item in raw) {
        if (item is List && item.length >= 2) {
          final a = (item[0] as num).toDouble();
          final b = (item[1] as num).toDouble();
          // GeoJSON standard coordinates: [lon, lat] where Hyderabad lon is ~78.x, lat ~17.x
          if (a > 50 && b < 40) {
            coords.add(LatLng(b, a));
          } else {
            coords.add(LatLng(a, b));
          }
        } else if (item is Map) {
          final lat = (item['latitude'] ?? item['lat']) as num?;
          final lon = (item['longitude'] ?? item['lon'] ?? item['lng']) as num?;
          if (lat != null && lon != null) {
            coords.add(LatLng(lat.toDouble(), lon.toDouble()));
          }
        }
      }
    }
    return coords;
  }

  /// Slices a polyline path into alternating dash segments and empty gaps.
  List<List<LatLng>> _splitIntoDashes(
    List<LatLng> points, {
    double dashMeters = 55.0,
    double gapMeters = 35.0,
  }) {
    if (points.length < 2) return [];
    final List<List<LatLng>> dashes = [];
    List<LatLng> currentDash = [];
    bool isDrawing = true;
    double accumulated = 0.0;

    LatLng current = points[0];
    if (isDrawing) currentDash.add(current);

    for (int i = 1; i < points.length; i++) {
      final target = points[i];
      var segDist = Geolocator.distanceBetween(
        current.latitude,
        current.longitude,
        target.latitude,
        target.longitude,
      );
      if (segDist <= 0.001) continue;

      var start = current;
      while (segDist > 0.001) {
        final targetDistance = isDrawing ? (dashMeters - accumulated) : (gapMeters - accumulated);
        if (segDist <= targetDistance) {
          accumulated += segDist;
          current = target;
          if (isDrawing) currentDash.add(current);
          if (accumulated >= (isDrawing ? dashMeters : gapMeters)) {
            if (isDrawing) {
              if (currentDash.length >= 2) dashes.add(List.from(currentDash));
              currentDash = [];
            } else {
              currentDash = [current];
            }
            isDrawing = !isDrawing;
            accumulated = 0.0;
          }
          break;
        } else {
          final fraction = targetDistance / segDist;
          final interpLat = start.latitude + fraction * (target.latitude - start.latitude);
          final interpLon = start.longitude + fraction * (target.longitude - start.longitude);
          final interpPoint = LatLng(interpLat, interpLon);

          current = interpPoint;
          start = interpPoint;
          segDist -= targetDistance;

          if (isDrawing) {
            currentDash.add(current);
            if (currentDash.length >= 2) dashes.add(List.from(currentDash));
            currentDash = [];
          } else {
            currentDash = [current];
          }
          isDrawing = !isDrawing;
          accumulated = 0.0;
        }
      }
    }

    if (isDrawing && currentDash.length >= 2) {
      dashes.add(currentDash);
    }
    return dashes;
  }

  /// Generates plausible alternative/rejected detour routes if backend did not include candidates.
  List<List<LatLng>> _generateAlternativeDetours(List<LatLng> recommended) {
    if (recommended.length < 3) return [];
    final List<LatLng> alt1 = [];
    final List<LatLng> alt2 = [];
    final n = recommended.length;

    for (int i = 0; i < n; i++) {
      final pt = recommended[i];
      final frac = i / (n - 1);
      final curve = sin(frac * pi); // Arc offset peaking at mid-route
      alt1.add(LatLng(pt.latitude + 0.009 * curve, pt.longitude - 0.007 * curve));
      alt2.add(LatLng(pt.latitude - 0.008 * curve, pt.longitude + 0.009 * curve));
    }
    return [alt1, alt2];
  }

  LatLngBounds _calculateBounds(List<LatLng> points) {
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLon = points.first.longitude;
    double maxLon = points.first.longitude;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }

    if (maxLat - minLat < 0.005) {
      minLat -= 0.003;
      maxLat += 0.003;
    }
    if (maxLon - minLon < 0.005) {
      minLon -= 0.003;
      maxLon += 0.003;
    }

    return LatLngBounds(
      southwest: LatLng(minLat, minLon),
      northeast: LatLng(maxLat, maxLon),
    );
  }

  Future<void> _applyRoutePayload(
    Map<String, dynamic> routePayload, {
    bool startDriveway = true,
  }) async {
    final map = _map;
    if (map == null) {
      _pendingRoutePayload = routePayload;
      return;
    }

    List<LatLng> recommended = [];
    List<List<LatLng>> rejectedGeometries = [];

    // 1. Inspect backend audit_routes response (routes array with is_recommended flag)
    if (routePayload['routes'] is List) {
      final routesList = routePayload['routes'] as List;
      for (final r in routesList) {
        if (r is Map) {
          final isRec = r['is_recommended'] == true ||
              (routePayload['recommended_route_id'] != null &&
                  r['route_id'] == routePayload['recommended_route_id']);
          final geom = r['geometry'];
          if (geom is Map && geom['coordinates'] != null) {
            final coords = _parseCoordinatesList(geom['coordinates']);
            if (isRec && recommended.isEmpty) {
              recommended = coords;
            } else if (!isRec && coords.length >= 2) {
              rejectedGeometries.add(coords);
            }
          }
        }
      }
    }

    // 2. Fallback to top-level geometry if recommended coordinates not yet set
    if (recommended.isEmpty) {
      dynamic geometry = routePayload['geometry'];
      if (geometry == null && routePayload['route'] != null) {
        geometry = routePayload['route']['geometry'];
      }
      if (geometry is Map && geometry['coordinates'] != null) {
        recommended = _parseCoordinatesList(geometry['coordinates']);
      } else if (routePayload['coordinates'] != null) {
        recommended = _parseCoordinatesList(routePayload['coordinates']);
      }
    }

    if (recommended.length < 2) {
      _message('Route payload has insufficient coordinates.');
      return;
    }

    // 3. Fallback for rejected routes
    if (rejectedGeometries.isEmpty) {
      final dynamic rejectedRaw =
          routePayload['rejected_routes'] ?? routePayload['alternatives'];
      if (rejectedRaw is List && rejectedRaw.isNotEmpty) {
        for (final rej in rejectedRaw) {
          if (rej is Map) {
            final geom = rej['geometry'] ?? rej;
            if (geom is Map && geom['coordinates'] != null) {
              final pts = _parseCoordinatesList(geom['coordinates']);
              if (pts.length >= 2) rejectedGeometries.add(pts);
            }
          } else if (rej is List) {
            final pts = _parseCoordinatesList(rej);
            if (pts.length >= 2) rejectedGeometries.add(pts);
          }
        }
      }
    }

    if (rejectedGeometries.isEmpty) {
      rejectedGeometries = _generateAlternativeDetours(recommended);
    }

    // 4. Update Text Inputs if names were provided
    if (routePayload['origin_name'] != null) {
      _originController.text = routePayload['origin_name'].toString();
    }
    if (routePayload['destination_name'] != null) {
      _destinationController.text = routePayload['destination_name'].toString();
    }

    // 5. Remove previous route lines
    if (_recommendedRouteLine != null) {
      try {
        await map.removeLine(_recommendedRouteLine!);
      } catch (_) {}
      _recommendedRouteLine = null;
    }
    for (final line in _rejectedRouteLines) {
      try {
        await map.removeLine(line);
      } catch (_) {}
    }
    _rejectedRouteLines.clear();

    // 6. Draw Rejected Routes in Dashed Gray (#94A3B8)
    for (final rej in rejectedGeometries) {
      final dashes = _splitIntoDashes(rej, dashMeters: 55.0, gapMeters: 35.0);
      for (final dash in dashes) {
        if (dash.length >= 2) {
          try {
            final line = await map.addLine(LineOptions(
              geometry: dash,
              lineColor: '#94A3B8', // Dashed gray
              lineWidth: 4.0,
              lineOpacity: 0.85,
            ));
            _rejectedRouteLines.add(line);
          } catch (_) {}
        }
      }
    }

    // 7. Draw Recommended Route in Bold Cyan/Teal (#00BCD4)
    _recommendedRouteLine = await map.addLine(LineOptions(
      geometry: recommended,
      lineColor: '#00BCD4', // Bold Cyan/Teal
      lineWidth: 6.5,       // Bold
      lineOpacity: 0.95,
    ));

    _recommendedCoordinates = recommended;
    _rejectedGeometries = rejectedGeometries;

    if (mounted) {
      setState(() => _navigationActive = true);
    }

    // 8. Start in-app driveway mode or fit overview bounds
    if (startDriveway) {
      await _startInAppDriveway();
    } else {
      final allPoints = <LatLng>[...recommended];
      for (final r in rejectedGeometries) {
        allPoints.addAll(r);
      }
      final bounds = _calculateBounds(allPoints);
      await map.animateCamera(
        CameraUpdate.newLatLngBounds(
          bounds,
          left: 45,
          top: 130,
          right: 45,
          bottom: 250,
        ),
        duration: const Duration(milliseconds: 900),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 3. Callback Controller: activateRecommendedRoute
  // ---------------------------------------------------------------------------

  /// Exposes a clean callback/controller method so the Chatbot tab can switch directly
  /// to the Map tab and launch in-app driveway mode for a recommended route.
  Future<void> activateRecommendedRoute(
    Map<String, dynamic> routePayload, {
    bool startDriveway = true,
  }) async {
    // 1. Ensure tab is switched to Map tab (tab index 0)
    NavigationController.instance.switchTab?.call(0);

    // 2. Render route lines (dashed gray rejected + bold cyan/teal recommended)
    // and launch in-app driveway mode (45° camera pitch, continuous progress simulation).
    await _applyRoutePayload(routePayload, startDriveway: startDriveway);
  }

  // ---------------------------------------------------------------------------
  // 2b. In-App Driveway Simulation & Progress Tracking
  // ---------------------------------------------------------------------------

  double _calculateBearing(LatLng start, LatLng end) {
    final lat1 = start.latitude * (pi / 180.0);
    final lon1 = start.longitude * (pi / 180.0);
    final lat2 = end.latitude * (pi / 180.0);
    final lon2 = end.longitude * (pi / 180.0);
    final dLon = lon2 - lon1;

    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    final radians = atan2(y, x);
    return (radians * (180.0 / pi) + 360.0) % 360.0;
  }

  List<LatLng> _resamplePathUniformly(List<LatLng> points, double stepMeters) {
    if (points.length < 2) return List.from(points);
    final List<LatLng> resampled = [points.first];
    LatLng current = points.first;

    for (int i = 1; i < points.length; i++) {
      final next = points[i];
      var segDist = Geolocator.distanceBetween(
        current.latitude,
        current.longitude,
        next.latitude,
        next.longitude,
      );
      if (segDist <= 0.001) continue;

      var start = current;
      while (segDist >= stepMeters) {
        final frac = stepMeters / segDist;
        final lat = start.latitude + frac * (next.latitude - start.latitude);
        final lon = start.longitude + frac * (next.longitude - start.longitude);
        final pt = LatLng(lat, lon);
        resampled.add(pt);
        current = pt;
        start = pt;
        segDist -= stepMeters;
      }
      current = next;
    }
    if (resampled.last != points.last) {
      resampled.add(points.last);
    }
    return resampled;
  }

  /// Starts the in-app driveway mode: tilts MapLibre camera to 45° pitch,
  /// adds vehicle symbol, and simulates/tracks driveway progress along the route inside the app.
  Future<void> _startInAppDriveway() async {
    final map = _map;
    if (map == null || _recommendedCoordinates.length < 2) return;

    _stopInAppDriveway(resetCamera: false);

    // Uniformly resample path every 22 meters for smooth tracking
    _drivewayWaypoints = _resamplePathUniformly(_recommendedCoordinates, 22.0);
    _drivewayIndex = 0;
    _drivewayProgress = 0.0;
    _drivewayCompleted = false;
    _drivewayPaused = false;
    _drivewayRemainingMeters = (_drivewayWaypoints.length - 1) * 22.0;
    _drivewayEtaMinutes = ((_drivewayRemainingMeters / 12.0) / 60.0).ceil();

    final startPoint = _drivewayWaypoints.first;
    final nextPoint = _drivewayWaypoints.length > 1 ? _drivewayWaypoints[1] : startPoint;
    final initialBearing = _calculateBearing(startPoint, nextPoint);

    setState(() {
      _drivewayActive = true;
    });

    // Tilts MapLibre camera (45° pitch) as required
    await map.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target: startPoint,
        zoom: 17.2,
        tilt: 45.0, // 45° pitch
        bearing: initialBearing,
      )),
      duration: const Duration(milliseconds: 1200),
    );

    // Add vehicle marker on the map
    _drivewayVehicleSymbol = await map.addSymbol(SymbolOptions(
      geometry: startPoint,
      iconImage: 'car-15',
      iconColor: '#00BCD4',
      iconSize: 1.8,
      textField: '🚗 Driveway',
      textSize: 10.5,
      textColor: '#004D40',
      textHaloColor: '#FFFFFF',
      textHaloWidth: 2.0,
      textOffset: const Offset(0, -2.0),
    ));

    // Simulation/tracking loop advancing along the route inside the app
    _drivewayTimer = Timer.periodic(const Duration(milliseconds: 700), (timer) async {
      if (!mounted || !_drivewayActive || _drivewayPaused) return;

      if (_drivewayIndex >= _drivewayWaypoints.length - 1) {
        timer.cancel();
        if (mounted) {
          setState(() {
            _drivewayProgress = 1.0;
            _drivewayRemainingMeters = 0.0;
            _drivewayEtaMinutes = 0;
            _drivewayCompleted = true;
          });
          _message('Arrived at destination! In-app driveway complete.');
        }
        return;
      }

      _drivewayIndex++;
      final currentPt = _drivewayWaypoints[_drivewayIndex];
      final nextPt = (_drivewayIndex + 1 < _drivewayWaypoints.length)
          ? _drivewayWaypoints[_drivewayIndex + 1]
          : currentPt;
      final bearing = _calculateBearing(currentPt, nextPt);

      // Check proximity to any reported road hazards along the route
      RoadHazard? nearby;
      for (final hazard in _hazards) {
        final dist = Geolocator.distanceBetween(
          currentPt.latitude,
          currentPt.longitude,
          hazard.latitude,
          hazard.longitude,
        );
        if (dist <= 50) {
          nearby = hazard;
          break;
        }
      }

      final progress = _drivewayIndex / (_drivewayWaypoints.length - 1);
      final remainingM = (_drivewayWaypoints.length - 1 - _drivewayIndex) * 22.0;
      final etaMin = ((remainingM / 12.0) / 60.0).ceil();

      if (mounted) {
        setState(() {
          _drivewayProgress = progress.clamp(0.0, 1.0);
          _drivewayRemainingMeters = remainingM;
          _drivewayEtaMinutes = etaMin > 0 ? etaMin : 1;
          _drivewayNearbyHazard = nearby;
        });
      }

      // Move vehicle symbol
      if (_drivewayVehicleSymbol != null && _map != null) {
        try {
          await _map!.updateSymbol(
            _drivewayVehicleSymbol!,
            SymbolOptions(geometry: currentPt),
          );
        } catch (_) {}
      }

      // Keep MapLibre camera tilted at 45° pitch, rotated to bearing, centered on vehicle
      if (_map != null) {
        try {
          await _map!.animateCamera(
            CameraUpdate.newCameraPosition(CameraPosition(
              target: currentPt,
              zoom: 17.2,
              tilt: 45.0, // Continuous 45° pitch in-app driveway
              bearing: bearing,
            )),
            duration: const Duration(milliseconds: 620),
          );
        } catch (_) {}
      }
    });

    _message('In-app driveway started (45° pitch camera). Never opening external maps.');
  }

  void _stopInAppDriveway({bool resetCamera = true}) {
    _drivewayTimer?.cancel();
    _drivewayTimer = null;

    if (_drivewayVehicleSymbol != null && _map != null) {
      try {
        _map!.removeSymbol(_drivewayVehicleSymbol!);
      } catch (_) {}
      _drivewayVehicleSymbol = null;
    }

    if (mounted) {
      setState(() {
        _drivewayActive = false;
        _drivewayPaused = false;
        _drivewayCompleted = false;
        _drivewayNearbyHazard = null;
      });
    }

    if (resetCamera && _map != null && _recommendedCoordinates.isNotEmpty) {
      final bounds = _calculateBounds(_recommendedCoordinates);
      _map!.animateCamera(
        CameraUpdate.newLatLngBounds(
          bounds,
          left: 45,
          top: 130,
          right: 45,
          bottom: 250,
        ),
        duration: const Duration(milliseconds: 900),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Hazard Verification & Reporting Handlers
  // ---------------------------------------------------------------------------

  void _checkNearbyHazards(Position position) {
    for (final hazard in _hazards) {
      if (_promptedIssueIds.contains(hazard.id)) continue;
      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        hazard.latitude,
        hazard.longitude,
      );
      if (distance <= 50) {
        _promptedIssueIds.add(hazard.id);
        if (mounted) {
          showProximityVerificationSheet(
            context,
            issueId: hazard.id,
            categoryLabel: hazard.category,
            distanceMeters: distance,
          ).then((result) {
            if (result != null) _loadHazards(force: true);
          });
        }
        break;
      }
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openReport() async {
    final result = await showNewIssueReportSheet(context);
    if (result != null) {
      await _loadHazards(force: true);
      _message('Hazard report submitted successfully!');
    }
  }

  // ---------------------------------------------------------------------------
  // UI Building Blocks
  // ---------------------------------------------------------------------------

  /// Compact 5-color legend bar on the map:
  /// GREEN (#22C55E Registered), BLUE (#3B82F6 Resolved), YELLOW (#EAB308 Still Active),
  /// ORANGE (#F97316 Impacting Others), RED (#EF4444 Ecosystem/Environment).
  Widget _buildCompactLegendBar() => Card(
        elevation: 3,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        color: Colors.white.withOpacity(0.96),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: HazardStatusConfig.all
                .map((cfg) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: cfg.color,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.2),
                            boxShadow: [
                              BoxShadow(
                                color: cfg.color.withOpacity(0.4),
                                blurRadius: 2,
                                spreadRadius: 0.5,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          cfg.label,
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ],
                    ))
                .toList(),
          ),
        ),
      );

  Widget _buildTopHeaderCard() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            elevation: 3,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            color: Colors.white.withOpacity(0.96),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.shield_outlined, color: Color(0xFF00838F), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_hazards.length} hazards in view · Hyderabad',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        if (_error != null)
                          Text(_error!,
                              style: const TextStyle(color: Colors.red, fontSize: 11)),
                        if (_position != null)
                          Text(
                            'GPS: ±${_position!.accuracy.toStringAsFixed(0)} m',
                            style: const TextStyle(
                                color: Color(0xFF64748B), fontSize: 10.5),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _loadHazards(force: true),
                    icon: const Icon(Icons.refresh, color: Color(0xFF00838F), size: 20),
                    tooltip: 'Refresh hazards',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          _buildCompactLegendBar(),
        ],
      );

  Widget _buildRoutePlannerCard() => Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A→B Place Name Inputs
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _originController,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'From (e.g. Gachibowli)',
                        prefixIcon: Icon(Icons.trip_origin,
                            size: 18, color: Color(0xFF22C55E)),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.swap_vert, color: Color(0xFF00838F)),
                    tooltip: 'Swap origin and destination',
                    onPressed: () {
                      final tmp = _originController.text;
                      _originController.text = _destinationController.text;
                      _destinationController.text = tmp;
                    },
                  ),
                  Expanded(
                    child: TextField(
                      controller: _destinationController,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'To (e.g. Tarnaka)',
                        prefixIcon: Icon(Icons.location_on,
                            size: 18, color: Color(0xFFEF4444)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF00838F),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _isPlanningRoute ? null : _planRoute,
                      icon: _isPlanningRoute
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.alt_route, size: 18),
                      label: Text(_isPlanningRoute
                          ? 'Planning…'
                          : (_navigationActive ? 'Refresh route' : 'Plan safer route')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _openReport,
                    icon: const Icon(Icons.camera_alt, size: 18),
                    label: const Text('Report'),
                  ),
                ],
              ),
              if (_recommendedCoordinates.isNotEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00838F),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                    onPressed: _startInAppDriveway,
                    icon: const Icon(Icons.navigation_rounded),
                    label: const Text(
                      'Start In-App Driveway',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                ),
              ],
              if (_navigationActive && !_drivewayActive) ...[
                const SizedBox(height: 2),
                TextButton(
                  onPressed: () {
                    setState(() => _navigationActive = false);
                    _startLocation();
                  },
                  child: const Text('End navigation checks'),
                ),
              ],
            ],
          ),
        ),
      );

  Widget _buildDrivewayTopHud() => Card(
        elevation: 5,
        color: const Color(0xFF004D40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: Color(0xFF00BCD4),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.navigation, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'IN-APP DRIVEWAY TRACKING',
                      style: TextStyle(
                        color: Color(0xFF80DEEA),
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        letterSpacing: 0.8,
                      ),
                    ),
                    Text(
                      _drivewayCompleted
                          ? 'Arrived at Destination'
                          : 'Cruising along recommended route · 45° Pitch',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '42 km/h',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildDrivewayHazardWarning() => Card(
        elevation: 4,
        color: const Color(0xFFF97316),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'CAUTION: ${_drivewayNearbyHazard!.category.replaceAll('_', ' ')} reported within 50m!',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildDrivewayBottomHud() => Card(
        elevation: 5,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${(_drivewayRemainingMeters / 1000).toStringAsFixed(1)} km',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF00838F),
                        ),
                      ),
                      const Text(
                        'Remaining distance',
                        style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '$_drivewayEtaMinutes min',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const Text(
                        'Estimated time',
                        style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: _drivewayProgress,
                backgroundColor: const Color(0xFFE2E8F0),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00BCD4)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() => _drivewayPaused = !_drivewayPaused);
                      },
                      icon: Icon(_drivewayPaused ? Icons.play_arrow : Icons.pause),
                      label: Text(_drivewayPaused ? 'Resume' : 'Pause'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFEE2E2),
                        foregroundColor: const Color(0xFFB91C1C),
                      ),
                      onPressed: () => _stopInAppDriveway(resetCamera: true),
                      icon: const Icon(Icons.close),
                      label: const Text('Exit Driveway'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Road watch · Hyderabad'),
          actions: [
            IconButton(
              onPressed: () => _loadHazards(force: true),
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh hazards',
            ),
          ],
        ),
        body: Stack(
          children: [
            MapLibreMap(
              styleString: 'https://demotiles.maplibre.org/style.json',
              initialCameraPosition:
                  const CameraPosition(target: hyderabad, zoom: 12.3),
              myLocationEnabled: true,
              myLocationTrackingMode: MyLocationTrackingMode.none,
              onMapCreated: _onMapCreated,
              onStyleLoadedCallback: _onStyleLoaded,
              onCameraIdle: () => _loadHazards(force: true),
            ),
            // Top HUD: Status Card & Compact 5-Color Legend OR Driveway Top HUD
            Positioned(
              left: 14,
              right: 14,
              top: 14,
              child: _drivewayActive ? _buildDrivewayTopHud() : _buildTopHeaderCard(),
            ),
            // Driveway Proximity Hazard Alert
            if (_drivewayActive && _drivewayNearbyHazard != null)
              Positioned(
                left: 14,
                right: 14,
                top: 86,
                child: _buildDrivewayHazardWarning(),
              ),
            // Bottom Controls: Route Planner Card OR Driveway HUD
            Positioned(
              left: 14,
              right: 14,
              bottom: 16,
              child: _drivewayActive
                  ? _buildDrivewayBottomHud()
                  : _buildRoutePlannerCard(),
            ),
          ],
        ),
      );
}

/// Road issue camera capture screen.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  CameraController? _camera;
  bool _busy = false;
  String? _error;
  String _category = 'pothole';

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (error) {
      if (mounted) setState(() => _error = 'Camera unavailable: $error');
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _captureAndSend() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final location =
          await requestCurrentPosition(LocationAccuracy.bestForNavigation);
      final capturedAt = DateTime.now().toUtc();
      final picture = await camera.takePicture();
      final file = File(picture.path);
      final contentType = picture.path.toLowerCase().endsWith('.png')
          ? 'image/png'
          : 'image/jpeg';
      final signed = await http.post(
        Uri.parse('$apiBase/api/v1/uploads/presign'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'file_name': picture.name,
          'content_type': contentType,
        }),
      );
      if (signed.statusCode != 200) {
        throw Exception(
            'Upload signing failed (${signed.statusCode}): ${signed.body}');
      }
      final upload = jsonDecode(signed.body) as Map<String, dynamic>;
      final uploaded = await http.put(
        Uri.parse(upload['upload_url'] as String),
        headers: Map<String, String>.from(upload['headers'] as Map),
        body: await file.readAsBytes(),
      );
      if (uploaded.statusCode < 200 || uploaded.statusCode >= 300) {
        throw Exception('Image upload failed (${uploaded.statusCode}).');
      }
      final report = await http.post(
        Uri.parse('$apiBase/api/v1/issues/report'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'category': _category,
          'description':
              'Citizen camera report: $_category. Captured ${location.timestamp.toUtc().toIso8601String()} with GPS accuracy ${location.accuracy.toStringAsFixed(1)} m.',
          'latitude': location.latitude,
          'longitude': location.longitude,
          'severity': 3,
          'evidence_image_url': upload['evidence_image_url'],
          'capture_accuracy_m': location.accuracy,
          'capture_heading_degrees': location.heading >= 0 && location.heading < 360
              ? location.heading
              : null,
          'captured_at': capturedAt.toIso8601String(),
        }),
      );
      if (report.statusCode != 201) {
        throw Exception('Report failed (${report.statusCode}): ${report.body}');
      }
      final issue = RoadHazard.fromJson(
          (jsonDecode(report.body) as Map<String, dynamic>)['issue']
              as Map<String, dynamic>);
      final vision = http.MultipartRequest(
        'POST',
        Uri.parse('$apiBase/api/v1/issues/${issue.id}/vision'),
      );
      vision.files.add(await http.MultipartFile.fromPath(
        'image',
        file.path,
        contentType: MediaType.parse(contentType),
      ));
      final visionResponse = await vision.send();
      if (visionResponse.statusCode != 202) {
        _error =
            'Report saved; vision assessment could not be queued (${visionResponse.statusCode}).';
      }
      if (mounted) Navigator.of(context).pop(issue);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Capture road issue')),
        body: Column(
          children: [
            Expanded(
              child: _camera?.value.isInitialized == true
                  ? CameraPreview(_camera!)
                  : Center(child: Text(_error ?? 'Opening camera…')),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _category,
                    decoration: const InputDecoration(labelText: 'Issue type'),
                    items: const [
                      DropdownMenuItem(value: 'pothole', child: Text('Pothole')),
                      DropdownMenuItem(
                          value: 'waterlogging', child: Text('Waterlogging')),
                      DropdownMenuItem(
                          value: 'damaged_surface',
                          child: Text('Damaged road surface')),
                      DropdownMenuItem(
                          value: 'open_manhole', child: Text('Open manhole')),
                      DropdownMenuItem(
                          value: 'broken_divider', child: Text('Broken divider')),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _category = value);
                    },
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _captureAndSend,
                      icon: const Icon(Icons.camera),
                      label: Text(_busy
                          ? 'Uploading and reporting…'
                          : 'Capture and report'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Location is sampled immediately before capture. Review traffic conditions before using your phone.',
                    style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
