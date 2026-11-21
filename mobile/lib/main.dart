import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'navigation_controller.dart';
import 'screens/chat_screen.dart';
import 'widgets/issue_detail_sheet.dart';
import 'widgets/survey_sheets.dart' hide showNewIssueReportSheet;
import 'widgets/survey_sheets.dart' as survey show showNewIssueReportSheet;

export 'navigation_controller.dart';

const apiBase = String.fromEnvironment(
  'RCMCA_API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8001',
);
const hyderabad = LatLng(17.3850, 78.4867);
const mapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';

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

    // Lightweight MethodChannel handler for deep links (e.g. rcmcs://navigate?route_id=...)
    const MethodChannel('rcmca/deeplink').setMethodCallHandler((call) async {
      if (call.method == 'onDeepLink' && call.arguments is String) {
        final uri = Uri.tryParse(call.arguments as String);
        if (uri != null) {
          await NavigationController.instance.handleDeepLinkUri(uri);
        }
      }
    });
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
                    'recommended_route_id': plan.routeId,
                    'label': plan.label,
                    'distance_m': plan.distanceKm * 1000.0,
                    'duration_s': plan.durationMin * 60.0,
                    'geometry': plan.geometry,
                    'hazards': plan.issuesOnRoute,
                    'routes': plan.routes,
                  });
                },
              ),
              NewIssueReportScreen(
                onSubmitted: (result) {
                  NavigationController.instance.switchTab?.call(0);
                },
              ),
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
  final Map<String, RoadHazard> _circleHazardMap = {};
  List<Symbol> _symbols = [];
  List<Circle> _circles = [];

  // Decluttered & Expanded UI state
  bool _legendExpanded = false;
  bool _routePlannerExpanded = false;

  // Route Hazard Highlighting & Total Count
  final List<Circle> _routeHazardCircles = [];
  int _routeHazardsCount = 0;
  int _routeHazardsAvoided = 0;
  String? _routeBannerText;

  // Triangular Vehicle Pointer & Heading in Driveway Mode
  Circle? _drivewayVehicleCircle;
  double _drivewayBearing = 0.0;

  // Direct Long-Press / Tap-to-Pin on Map
  LatLng? _pinnedLocation;
  Circle? _pinnedCircle;
  Symbol? _pinnedSymbol;

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

  // In-App Driveway State (Real Live GPS Movement via Geolocator.getPositionStream)
  bool _drivewayActive = false;
  StreamSubscription<Position>? _drivewayPositionSubscription;
  Position? _lastDrivewayPosition;
  double _drivewayRemainingMeters = 0.0;
  int _drivewayEtaMinutes = 0;
  RoadHazard? _drivewayNearbyHazard;
  Symbol? _drivewayVehicleSymbol;

  // Refresh status
  bool _isRefreshing = false;

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

    // Register callback for deep link navigation (rcmcs://navigate?route_id=...)
    NavigationController.instance.onDeepLinkRoute = ({
      String? routeId,
      String? origin,
      String? destination,
    }) async {
      await _handleDeepLinkRoute(
        routeId: routeId,
        origin: origin,
        destination: destination,
      );
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
    _drivewayPositionSubscription?.cancel();
    _positionSubscription?.cancel();
    _originController.dispose();
    _destinationController.dispose();
    if (NavigationController.instance.onActivateRecommendedRoute != null) {
      NavigationController.instance.onActivateRecommendedRoute = null;
    }
    if (NavigationController.instance.onDeepLinkRoute != null) {
      NavigationController.instance.onDeepLinkRoute = null;
    }
    super.dispose();
  }

  /// Handles deep links like `rcmcs://navigate?route_id=...`
  Future<void> _handleDeepLinkRoute({
    String? routeId,
    String? origin,
    String? destination,
  }) async {
    if (origin != null && origin.isNotEmpty) {
      _originController.text = origin;
    }
    if (destination != null && destination.isNotEmpty) {
      _destinationController.text = destination;
    }

    final last = NavigationController.instance.lastRoutePayload;
    if (last != null &&
        routeId != null &&
        (last['recommended_route_id'] == routeId ||
         last['route_id'] == routeId)) {
      await activateRecommendedRoute(last, startDriveway: true);
      return;
    }

    await _planRoute();
    if (_recommendedCoordinates.isNotEmpty) {
      await _startInAppDriveway();
    }
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
    controller.onCircleTapped.add((circle) {
      final hazard = _circleHazardMap[circle.id];
      if (hazard != null && mounted) {
        showIssueDetailSheet(
          context,
          issue: hazard.rawJson,
        ).then((_) => _loadHazards(force: true));
      }
    });
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

      final oldSymbols = _symbols;
      final oldCircles = _circles;
      _symbols = [];
      _circles = [];
      _symbolHazardMap.clear();
      _circleHazardMap.clear();
      if (oldSymbols.isNotEmpty) {
        try {
          await map.removeSymbols(oldSymbols);
        } catch (_) {
          for (final s in oldSymbols) {
            await map.removeSymbol(s);
          }
        }
      }
      if (oldCircles.isNotEmpty) {
        try {
          await map.removeCircles(oldCircles);
        } catch (_) {
          for (final c in oldCircles) {
            await map.removeCircle(c);
          }
        }
      }

      // Render pins color-coded by status_color:
      // GREEN (#22C55E), BLUE (#3B82F6), YELLOW (#EAB308), ORANGE (#F97316), RED (#EF4444)
      // Vector styles like OpenFreeMap Liberty don't include marker-15 sprites,
      // so native Circle markers draw the visible colored pin dots reliably.
      for (final hazard in hazards) {
        final circle = await map.addCircle(CircleOptions(
          geometry: LatLng(hazard.latitude, hazard.longitude),
          circleColor: hazard.statusHexColor,
          circleRadius: hazard.severity >= 4 ? 8.5 : 6.5,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2.0,
          circleOpacity: 1.0,
        ));
        _circles.add(circle);
        _circleHazardMap[circle.id] = hazard;

        final symbol = await map.addSymbol(SymbolOptions(
          geometry: LatLng(hazard.latitude, hazard.longitude),
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
                  r['route_id'] == routePayload['recommended_route_id']) ||
              (routePayload['route_id'] != null &&
                  r['route_id'] == routePayload['route_id']);
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

    // 4. Update Text Inputs if names were provided
    if (routePayload['origin_name'] != null) {
      _originController.text = routePayload['origin_name'].toString();
    }
    if (routePayload['destination_name'] != null) {
      _destinationController.text = routePayload['destination_name'].toString();
    }

    // 5. Remove previous route lines & hazard highlight markers
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

    if (_routeHazardCircles.isNotEmpty) {
      try {
        await map.removeCircles(_routeHazardCircles);
      } catch (_) {
        for (final c in _routeHazardCircles) {
          await map.removeCircle(c);
        }
      }
      _routeHazardCircles.clear();
    }

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

    // 7b. Highlight route hazards with enlarged ringed markers and compute total count
    Map<String, dynamic>? recommendedRoute;
    if (routePayload['routes'] is List) {
      for (final r in routePayload['routes']) {
        if (r is Map &&
            (r['is_recommended'] == true ||
                (routePayload['recommended_route_id'] != null &&
                    r['route_id'] == routePayload['recommended_route_id']) ||
                (routePayload['route_id'] != null &&
                    r['route_id'] == routePayload['route_id']))) {
          recommendedRoute = Map<String, dynamic>.from(r);
          break;
        }
      }
    }

    final dynamic rawRouteHazards = recommendedRoute?['issues_on_route'] ??
        routePayload['hazards'] ??
        routePayload['issues_on_route'];
    final List<Map<String, dynamic>> routeHazards = [];
    if (rawRouteHazards is List) {
      for (final h in rawRouteHazards) {
        if (h is Map) routeHazards.add(Map<String, dynamic>.from(h));
      }
    }

    // Determine avoided hazards count across alternative rejected routes
    final Set<String> recIds = routeHazards
        .map((e) => (e['id'] ?? e['title'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    final Set<String> avoidedIds = {};
    if (routePayload['routes'] is List) {
      for (final r in routePayload['routes']) {
        if (r is Map && r['is_recommended'] != true && r['issues_on_route'] is List) {
          for (final issue in r['issues_on_route']) {
            if (issue is Map) {
              final id = (issue['id'] ?? issue['title'] ?? '').toString();
              if (id.isNotEmpty && !recIds.contains(id)) {
                avoidedIds.add(id);
              }
            }
          }
        }
      }
    }
    final int totalAvoided = avoidedIds.length;

    final count = routeHazards.length;
    final bannerText =
        '$count hazard${count == 1 ? '' : 's'} along recommended route · $totalAvoided avoided';

    // Highlight each hazard in issues_on_route on the MapLibre canvas with enlarged ringed markers
    for (final issue in routeHazards) {
      final lat = (issue['latitude'] ?? issue['lat']) as num?;
      final lon = (issue['longitude'] ?? issue['lon'] ?? issue['lng']) as num?;
      if (lat != null && lon != null) {
        final statusColor = issue['status_color']?.toString() ?? 'RED';
        final config = HazardStatusConfig.fromKey(statusColor);
        final pt = LatLng(lat.toDouble(), lon.toDouble());

        try {
          // Enlarged outer ring marker (radius 16.0 with prominent stroke)
          final outerRing = await map.addCircle(CircleOptions(
            geometry: pt,
            circleColor: config.hex,
            circleOpacity: 0.22,
            circleRadius: 16.0,
            circleStrokeColor: config.hex,
            circleStrokeWidth: 3.5,
            circleStrokeOpacity: 0.95,
          ));
          _routeHazardCircles.add(outerRing);

          // Inner core circle marker (radius 8.5)
          final innerCore = await map.addCircle(CircleOptions(
            geometry: pt,
            circleColor: config.hex,
            circleOpacity: 1.0,
            circleRadius: 8.5,
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 2.0,
          ));
          _routeHazardCircles.add(innerCore);
        } catch (_) {}
      }
    }

    if (mounted) {
      setState(() {
        _navigationActive = true;
        _routeHazardsCount = count;
        _routeHazardsAvoided = totalAvoided;
        _routeBannerText = bannerText;
        _routePlannerExpanded = false; // Collapse bottom card to keep >75% map canvas
      });
    }

    // Automatically start continuous location proximity stream whenever a route is activated
    _navigationActive = true;
    unawaited(_startLocation());

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

    // 3. Automatically ensure continuous location proximity check is running
    _navigationActive = true;
    unawaited(_startLocation());
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
  /// adds triangular vehicle pointer, and tracks real live device GPS movement via getPositionStream.
  Future<void> _startInAppDriveway() async {
    final map = _map;
    if (map == null || _recommendedCoordinates.length < 2) return;

    _stopInAppDriveway(resetCamera: false);

    Position initialPos;
    try {
      initialPos = await requestCurrentPosition(LocationAccuracy.bestForNavigation);
      _position = initialPos;
    } catch (e) {
      if (_position != null) {
        initialPos = _position!;
      } else {
        _message('Location permission is needed for live GPS driveway navigation.');
        return;
      }
    }

    final initialTarget = LatLng(initialPos.latitude, initialPos.longitude);
    final initialBearing = (initialPos.heading > 0)
        ? initialPos.heading
        : _calculateBearing(
            _recommendedCoordinates.first,
            _recommendedCoordinates.length > 1
                ? _recommendedCoordinates[1]
                : _recommendedCoordinates.first,
          );

    final initialDest = _recommendedCoordinates.last;
    final initialRemainingM = Geolocator.distanceBetween(
      initialTarget.latitude,
      initialTarget.longitude,
      initialDest.latitude,
      initialDest.longitude,
    );
    final initialEtaMin = ((initialRemainingM / 12.0) / 60.0).ceil();

    setState(() {
      _drivewayActive = true;
      _drivewayBearing = initialBearing;
      _lastDrivewayPosition = initialPos;
      _drivewayRemainingMeters = initialRemainingM;
      _drivewayEtaMinutes = initialEtaMin > 0 ? initialEtaMin : 1;
      _routePlannerExpanded = false;
    });

    // Tilts MapLibre camera (45° pitch)
    await map.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target: initialTarget,
        zoom: 17.5,
        tilt: 45.0, // 45° pitch
        bearing: initialBearing,
      )),
      duration: const Duration(milliseconds: 1000),
    );

    // Prominent triangular navigation pointer aligned with heading/bearing along cyan route line
    try {
      _drivewayVehicleCircle = await map.addCircle(CircleOptions(
        geometry: initialTarget,
        circleColor: '#00E5FF',
        circleRadius: 11.0,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3.0,
        circleOpacity: 0.95,
      ));

      _drivewayVehicleSymbol = await map.addSymbol(SymbolOptions(
        geometry: initialTarget,
        textField: '▲', // Prominent triangular navigation arrow pointer
        textSize: 32.0,
        textColor: '#006064',
        textHaloColor: '#FFFFFF',
        textHaloWidth: 3.5,
        textRotate: initialBearing, // Aligned with heading/bearing along route
        textOffset: const Offset(0, 0),
      ));
    } catch (_) {}

    // Subscribe to real live GPS movement via Geolocator.getPositionStream(...)
    final locationSettings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 2,
            intervalDuration: const Duration(milliseconds: 1000),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'RCMCA Driveway Active',
              notificationText: 'Live GPS navigation tracking in progress.',
              enableWakeLock: true,
              setOngoing: true,
            ),
          )
        : AppleSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 2,
            activityType: ActivityType.automotiveNavigation,
          );

    _drivewayPositionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position pos) async {
      if (!mounted || !_drivewayActive || _map == null) return;

      final currentPt = LatLng(pos.latitude, pos.longitude);
      double bearing = pos.heading;

      // If device course/heading is unavailable (stationary or 0), deduce bearing from last GPS point
      if (bearing <= 0.0 && _lastDrivewayPosition != null) {
        final dist = Geolocator.distanceBetween(
          _lastDrivewayPosition!.latitude,
          _lastDrivewayPosition!.longitude,
          pos.latitude,
          pos.longitude,
        );
        if (dist >= 1.5) {
          bearing = _calculateBearing(
            LatLng(_lastDrivewayPosition!.latitude, _lastDrivewayPosition!.longitude),
            currentPt,
          );
        } else {
          bearing = _drivewayBearing;
        }
      }

      // Check proximity to any reported road hazards along route (within 50m)
      RoadHazard? nearby;
      for (final hazard in _hazards) {
        final dist = Geolocator.distanceBetween(
          pos.latitude,
          pos.longitude,
          hazard.latitude,
          hazard.longitude,
        );
        if (dist <= 50) {
          nearby = hazard;
          break;
        }
      }

      if (_navigationActive || _drivewayActive) {
        _checkNearbyHazards(pos);
      }

      // Remaining distance along recommended coordinates to destination
      final dest = _recommendedCoordinates.last;
      final remainingM = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        dest.latitude,
        dest.longitude,
      );
      final etaMin = ((remainingM / 12.0) / 60.0).ceil();

      if (mounted) {
        setState(() {
          _position = pos;
          _lastDrivewayPosition = pos;
          _drivewayBearing = bearing;
          _drivewayNearbyHazard = nearby;
          _drivewayRemainingMeters = remainingM;
          _drivewayEtaMinutes = etaMin > 0 ? etaMin : 1;
        });
      }

      // Position and rotate the triangular vehicle pointer strictly from real device GPS
      if (_drivewayVehicleSymbol != null) {
        try {
          await _map!.updateSymbol(
            _drivewayVehicleSymbol!,
            SymbolOptions(
              geometry: currentPt,
              textRotate: bearing,
            ),
          );
        } catch (_) {}
      }
      if (_drivewayVehicleCircle != null) {
        try {
          await _map!.updateCircle(
            _drivewayVehicleCircle!,
            CircleOptions(geometry: currentPt),
          );
        } catch (_) {}
      }

      // Keep MapLibre camera tilted at 45° pitch, rotated to bearing, centered on vehicle
      try {
        await _map!.animateCamera(
          CameraUpdate.newCameraPosition(CameraPosition(
            target: currentPt,
            zoom: 17.5,
            tilt: 45.0, // Continuous 45° pitch in-app driveway
            bearing: bearing,
          )),
          duration: const Duration(milliseconds: 650),
        );
      } catch (_) {}
    }, onError: (Object err) {
      debugPrint('Driveway GPS error: $err');
    });

    _message('Live GPS Driveway started (45° pitch camera). Never opening external maps.');
  }

  void _stopInAppDriveway({bool resetCamera = true}) {
    _drivewayPositionSubscription?.cancel();
    _drivewayPositionSubscription = null;
    _lastDrivewayPosition = null;

    if (_drivewayVehicleCircle != null && _map != null) {
      try {
        _map!.removeCircle(_drivewayVehicleCircle!);
      } catch (_) {}
      _drivewayVehicleCircle = null;
    }
    if (_drivewayVehicleSymbol != null && _map != null) {
      try {
        _map!.removeSymbol(_drivewayVehicleSymbol!);
      } catch (_) {}
      _drivewayVehicleSymbol = null;
    }

    if (mounted) {
      setState(() {
        _drivewayActive = false;
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

  Future<void> _openReport({LatLng? pinnedLocation}) async {
    final result = await showNewIssueReportSheet(
      context,
      pinnedLocation: pinnedLocation,
    );
    if (result != null) {
      await _loadHazards(force: true);
      _message('Hazard report submitted successfully!');
    }
  }

  /// Drops a pin at the current center of the map viewport.
  Future<void> _dropPinAtCenter() async {
    final map = _map;
    if (map == null) return;
    try {
      final region = await map.getVisibleRegion();
      final center = LatLng(
        (region.northeast.latitude + region.southwest.latitude) / 2.0,
        (region.northeast.longitude + region.southwest.longitude) / 2.0,
      );
      await _handleMapLongClick(center);
    } catch (_) {
      await _handleMapLongClick(hyderabad);
    }
  }

  /// Handles direct long-press on any road on MapLibre: drops a high-contrast pin
  /// and opens showNewIssueReportSheet pre-populated with that pinned road coordinate.
  Future<void> _handleMapLongClick(LatLng coords) async {
    final map = _map;
    if (map == null) return;

    if (_pinnedCircle != null) {
      try {
        await map.removeCircle(_pinnedCircle!);
      } catch (_) {}
      _pinnedCircle = null;
    }
    if (_pinnedSymbol != null) {
      try {
        await map.removeSymbol(_pinnedSymbol!);
      } catch (_) {}
      _pinnedSymbol = null;
    }

    setState(() => _pinnedLocation = coords);

    try {
      _pinnedCircle = await map.addCircle(CircleOptions(
        geometry: coords,
        circleColor: '#EF4444',
        circleRadius: 11.0,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3.0,
        circleOpacity: 1.0,
      ));

      _pinnedSymbol = await map.addSymbol(SymbolOptions(
        geometry: coords,
        textField:
            '📍 Pinned Road\n${coords.latitude.toStringAsFixed(4)}, ${coords.longitude.toStringAsFixed(4)}',
        textSize: 11.0,
        textColor: '#7F1D1D',
        textHaloColor: '#FFFFFF',
        textHaloWidth: 2.0,
        textOffset: const Offset(0, 1.8),
      ));
    } catch (_) {}

    await _openReport(pinnedLocation: coords);
  }

  /// Clears any custom pinned road marker from the map.
  Future<void> _clearPinnedLocation() async {
    final map = _map;
    if (map != null) {
      if (_pinnedCircle != null) {
        try {
          await map.removeCircle(_pinnedCircle!);
        } catch (_) {}
        _pinnedCircle = null;
      }
      if (_pinnedSymbol != null) {
        try {
          await map.removeSymbol(_pinnedSymbol!);
        } catch (_) {}
        _pinnedSymbol = null;
      }
    }
    if (mounted) {
      setState(() => _pinnedLocation = null);
      _message('Pinned location cleared');
    }
  }

  /// Calls POST /api/v1/issues/refresh to scrape news & seed 100 realistic issues,
  /// then reloads all map markers and notifies the user with the updated count.
  Future<void> _refreshAndReloadHazards() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      _message('Refreshing civic news & road hazards…');
      try {
        final refreshUri = Uri.parse('$apiBase/api/v1/issues/refresh');
        final resp = await http.post(refreshUri).timeout(const Duration(seconds: 15));
        debugPrint('Refresh response: ${resp.statusCode}');
      } catch (e) {
        debugPrint('Scrape refresh endpoint note: $e');
      }

      await _loadHazards(force: true);

      _message('Loaded ${_hazards.length} civic road hazards in Hyderabad');
    } catch (e) {
      _message('Reload completed: ${_hazards.length} hazards active');
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  // ---------------------------------------------------------------------------
  // UI Building Blocks (Decluttered Map Layout)
  // ---------------------------------------------------------------------------

  /// Compact expandable 5-color legend pill chip:
  /// Collapsed by default to keep >75% of screen as open map canvas.
  Widget _buildCompactLegendPill() => InkWell(
        onTap: () => setState(() => _legendExpanded = !_legendExpanded),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFCBD5E1)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final cfg in HazardStatusConfig.all) ...[
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  decoration: BoxDecoration(
                    color: cfg.color,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              const SizedBox(width: 5),
              const Text(
                'Legend',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF334155),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                _legendExpanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 15,
                color: const Color(0xFF64748B),
              ),
            ],
          ),
        ),
      );

  Widget _buildExpandedLegendCard() => Card(
        elevation: 3,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        color: Colors.white.withOpacity(0.97),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 4,
            children: HazardStatusConfig.all
                .map((cfg) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8.5,
                          height: 8.5,
                          decoration: BoxDecoration(
                            color: cfg.color,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.2),
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
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            color: Colors.white.withOpacity(0.96),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.shield_outlined,
                      color: Color(0xFF00838F), size: 18),
                  const SizedBox(width: 6),
                  Text(
                    '${_hazards.length} hazards',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12.5,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildCompactLegendPill(),
                  const Spacer(),
                  IconButton(
                    onPressed: _dropPinAtCenter,
                    icon: const Icon(Icons.add_location_alt_outlined,
                        color: Color(0xFF00838F), size: 20),
                    tooltip: 'Drop Pin on Map',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    onPressed: () => _loadHazards(force: true),
                    icon: const Icon(Icons.refresh,
                        color: Color(0xFF00838F), size: 20),
                    tooltip: 'Refresh hazards',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
          if (_legendExpanded) ...[
            const SizedBox(height: 4),
            _buildExpandedLegendCard(),
          ],
        ],
      );

  /// Banner displaying the total count of issues along the route and issues avoided.
  Widget _buildRouteHazardBanner() {
    if (_routeBannerText == null) return const SizedBox.shrink();
    final hasHazards = _routeHazardsCount > 0;
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: hasHazards ? const Color(0xFFFFF7ED) : const Color(0xFFF0FDF4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasHazards
                  ? Icons.warning_amber_rounded
                  : Icons.verified_user_outlined,
              color:
                  hasHazards ? const Color(0xFFEA580C) : const Color(0xFF16A34A),
              size: 19,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _routeBannerText!,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: hasHazards
                      ? const Color(0xFF9A3412)
                      : const Color(0xFF166534),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Collapsible / compact bottom route planner card ensuring >75% map canvas.
  Widget _buildRoutePlannerCard() {
    if (!_routePlannerExpanded) {
      return Card(
        elevation: 3,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        color: Colors.white.withOpacity(0.97),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _routePlannerExpanded = true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.alt_route, color: Color(0xFF00838F), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _recommendedCoordinates.isNotEmpty
                        ? '${_originController.text} → ${_destinationController.text}'
                        : 'Plan route: ${_originController.text} → ${_destinationController.text}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                      color: Color(0xFF0F172A),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_recommendedCoordinates.isNotEmpty) ...[
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00838F),
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: _startInAppDriveway,
                    icon: const Icon(Icons.navigation_rounded, size: 14),
                    label: const Text('Driveway', style: TextStyle(fontSize: 11.5)),
                  ),
                  const SizedBox(width: 4),
                ] else ...[
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF00838F),
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: _isPlanningRoute ? null : _planRoute,
                    icon: _isPlanningRoute
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.arrow_forward, size: 18),
                    tooltip: 'Plan route',
                  ),
                  const SizedBox(width: 4),
                ],
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_up,
                      color: Color(0xFF00838F), size: 20),
                  tooltip: 'Expand route planner',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _routePlannerExpanded = true),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.route, color: Color(0xFF00838F), size: 18),
                const SizedBox(width: 6),
                const Text('Route Planner',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down,
                      color: Color(0xFF64748B), size: 20),
                  tooltip: 'Collapse',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _routePlannerExpanded = false),
                ),
              ],
            ),
            // A→B Place Name Inputs with Single Arrow Button
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _originController,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'From',
                      hintText: 'e.g. Gachibowli',
                      prefixIcon: Icon(Icons.trip_origin,
                          size: 16, color: Color(0xFF22C55E)),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.swap_horiz, color: Color(0xFF00838F)),
                  tooltip: 'Swap origin and destination',
                  visualDensity: VisualDensity.compact,
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
                      labelText: 'To',
                      hintText: 'e.g. Tarnaka',
                      prefixIcon: Icon(Icons.location_on,
                          size: 16, color: Color(0xFFEF4444)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF00838F),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _isPlanningRoute ? null : _planRoute,
                  icon: _isPlanningRoute
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.arrow_forward),
                  tooltip: 'Plan route',
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
  }

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

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Road watch · Hyderabad'),
          actions: [
            if (_isRefreshing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              IconButton(
                onPressed: _refreshAndReloadHazards,
                icon: const Icon(Icons.refresh),
                tooltip: 'Scrape news & reload hazards',
              ),
          ],
        ),
        body: Stack(
          children: [
            MapLibreMap(
              styleString: mapStyleUrl,
              initialCameraPosition:
                  const CameraPosition(target: hyderabad, zoom: 12.3),
              myLocationEnabled: true,
              myLocationTrackingMode: MyLocationTrackingMode.none,
              onMapCreated: _onMapCreated,
              onStyleLoadedCallback: _onStyleLoaded,
              onCameraIdle: () => _loadHazards(force: true),
              onMapLongClick: (Point<double> point, LatLng coordinates) {
                _handleMapLongClick(coordinates);
              },
            ),
            // Compact top Driveway status chip with live distance, ETA, and Exit button
            if (_drivewayActive)
              Positioned(
                top: 14,
                left: 14,
                right: 14,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF004D40).withOpacity(0.95),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.navigation, size: 15, color: Color(0xFF80DEEA)),
                          const SizedBox(width: 6),
                          Text(
                            '${(_drivewayRemainingMeters / 1000.0).toStringAsFixed(1)} km · $_drivewayEtaMinutes min',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    ActionChip(
                      avatar: const Icon(Icons.close, size: 15, color: Color(0xFFB91C1C)),
                      label: const Text(
                        'Exit Driveway',
                        style: TextStyle(
                          color: Color(0xFFB91C1C),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      backgroundColor: const Color(0xFFFEE2E2),
                      side: const BorderSide(color: Color(0xFFFCA5A5)),
                      onPressed: () => _stopInAppDriveway(resetCamera: true),
                    ),
                  ],
                ),
              ),
            // Floating "Unpin" action button/chip for accidental long-press pins
            if (!_drivewayActive && _pinnedLocation != null)
              Positioned(
                top: 14,
                right: 14,
                child: ActionChip(
                  avatar: const Icon(Icons.close, size: 16, color: Color(0xFFB91C1C)),
                  label: const Text(
                    'Unpin',
                    style: TextStyle(
                      color: Color(0xFFB91C1C),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  backgroundColor: const Color(0xFFFEE2E2),
                  side: const BorderSide(color: Color(0xFFFCA5A5)),
                  onPressed: _clearPinnedLocation,
                ),
              ),
            // Route Hazard Highlighting & Total Count Banner
            if (!_drivewayActive && _routeBannerText != null)
              Positioned(
                left: 14,
                right: _pinnedLocation != null ? 100 : 14,
                top: 14,
                child: _buildRouteHazardBanner(),
              ),
            // Driveway Proximity Hazard Alert
            if (_drivewayActive && _drivewayNearbyHazard != null)
              Positioned(
                left: 14,
                right: 14,
                top: 60,
                child: _buildDrivewayHazardWarning(),
              ),
            // Bottom Controls: Collapsible Route Planner Card (no player bar during driveway)
            if (!_drivewayActive)
              Positioned(
                left: 14,
                right: 14,
                bottom: 16,
                child: _buildRoutePlannerCard(),
              ),
          ],
        ),
      );
}

/// Road issue capture screen using 4-layer report workflow and local uploads.
class CaptureScreen extends StatelessWidget {
  const CaptureScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return NewIssueReportScreen(
      onSubmitted: (result) {
        NavigationController.instance.switchTab?.call(0);
      },
    );
  }
}

/// Opens the 4-layer new-issue report sheet.
/// When [pinnedLocation] is provided, pre-populates with that pinned road coordinate.
Future<ReportedIssueResult?> showNewIssueReportSheet(
  BuildContext context, {
  ValueChanged<ReportedIssueResult>? onSubmitted,
  LatLng? pinnedLocation,
}) {
  if (pinnedLocation != null) {
    return showModalBottomSheet<ReportedIssueResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _PinnedIssueReportSheet(
        pinnedLocation: pinnedLocation,
        onSubmitted: onSubmitted,
      ),
    );
  }
  return survey.showNewIssueReportSheet(context, onSubmitted: onSubmitted);
}

/// Modal sheet for pre-populated road pin reports
class _PinnedIssueReportSheet extends StatefulWidget {
  const _PinnedIssueReportSheet({
    required this.pinnedLocation,
    this.onSubmitted,
  });

  final LatLng pinnedLocation;
  final ValueChanged<ReportedIssueResult>? onSubmitted;

  @override
  State<_PinnedIssueReportSheet> createState() => _PinnedIssueReportSheetState();
}

class _PinnedIssueReportSheetState extends State<_PinnedIssueReportSheet> {
  final TextEditingController _description = TextEditingController();
  int _conditionScore = 3;
  String _impact = 'Civic hazard';
  String _category = 'pothole';
  final bool _stillPresent = true;
  bool _submitting = false;
  String? _error;

  static const List<Map<String, String>> _categories = [
    {'key': 'pothole', 'label': 'Pothole'},
    {'key': 'waterlogging', 'label': 'Waterlogging'},
    {'key': 'damaged_surface', 'label': 'Damaged surface'},
    {'key': 'open_manhole', 'label': 'Open manhole'},
    {'key': 'broken_divider', 'label': 'Broken divider'},
  ];

  static const List<Map<String, dynamic>> _conditions = [
    {'score': 1, 'label': 'Passable', 'color': Color(0xFF22C55E)},
    {'score': 2, 'label': 'Minor', 'color': Color(0xFF3B82F6)},
    {'score': 3, 'label': 'Moderate', 'color': Color(0xFFEAB308)},
    {'score': 4, 'label': 'Severe', 'color': Color(0xFFF97316)},
    {'score': 5, 'label': 'Impassable', 'color': Color(0xFFEF4444)},
  ];

  static const List<String> _impacts = [
    'Civic hazard',
    'Traffic congestion',
    'Safety risk',
    'Eco / drainage hazard',
  ];

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final desc = _description.text.trim();
    if (desc.length < 8) {
      setState(() => _error = 'Enter a description of at least 8 characters.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$apiBase/api/v1/issues/report'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'category': _category,
              'description': desc,
              'latitude': widget.pinnedLocation.latitude,
              'longitude': widget.pinnedLocation.longitude,
              'severity': _conditionScore,
              'still_present': _stillPresent,
              'condition_score': _conditionScore,
              'impact_mcq': _impact,
              'capture_accuracy_m': 1.0,
              'captured_at': DateTime.now().toUtc().toIso8601String(),
            }),
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode != 201) {
        throw Exception('Report failed (${response.statusCode}): ${response.body}');
      }

      final result = ReportedIssueResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );

      if (!mounted) return;
      widget.onSubmitted?.call(result);
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        18,
        12,
        18,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Report at Pinned Road',
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Coordinates locked directly from map pin',
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Pinned Location Card
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFCBD5E1)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.pin_drop, color: Color(0xFFEF4444), size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Pinned Road Coordinates',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                        Text(
                          '${widget.pinnedLocation.latitude.toStringAsFixed(5)}, ${widget.pinnedLocation.longitude.toStringAsFixed(5)}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Chip(
                    label: Text('Pinned', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: Color(0xFFFEE2E2),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Category
            const Text('Issue Type', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _categories.map((cat) {
                final selected = _category == cat['key'];
                return ChoiceChip(
                  label: Text(cat['label']!),
                  selected: selected,
                  onSelected: (val) {
                    if (val) setState(() => _category = cat['key']!);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            // Severity
            const Text('Condition Severity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _conditions.map((cond) {
                final selected = _conditionScore == cond['score'];
                return ChoiceChip(
                  label: Text('${cond['score']} · ${cond['label']}'),
                  selected: selected,
                  selectedColor: (cond['color'] as Color).withOpacity(0.2),
                  onSelected: (val) {
                    if (val) setState(() => _conditionScore = cond['score'] as int);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            // Impact
            const Text('Public Impact', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _impacts.map((imp) {
                final selected = _impact == imp;
                return ChoiceChip(
                  label: Text(imp),
                  selected: selected,
                  onSelected: (val) {
                    if (val) setState(() => _impact = imp);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            // Description
            TextField(
              controller: _description,
              decoration: const InputDecoration(
                labelText: 'Description (at least 8 characters)',
                hintText: 'e.g. Deep pothole across road lane near junction',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: 2,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00838F),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send),
              label: Text(_submitting ? 'Submitting…' : 'Submit Report at Pin'),
            ),
          ],
        ),
      ),
    );
  }
}
