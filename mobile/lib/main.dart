import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const apiBase = String.fromEnvironment(
  'RCMCA_API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8001',
);
const hyderabad = LatLng(17.3850, 78.4867);

Future<Position> requestCurrentPosition(LocationAccuracy accuracy) async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw Exception('Turn on device location and try again.');
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
  if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
    throw Exception('Location permission is needed for road reports and navigation.');
  }
  return Geolocator.getCurrentPosition(
    locationSettings: LocationSettings(accuracy: accuracy, timeLimit: const Duration(seconds: 12)),
  );
}

void main() => runApp(const RcmcaApp());

class RcmcaApp extends StatelessWidget {
  const RcmcaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RCMCA',
        theme: ThemeData(colorSchemeSeed: const Color(0xff147d64), useMaterial3: true),
        home: const RoadMapScreen(),
      );
}

class RoadHazard {
  RoadHazard.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String,
        category = json['category'] as String,
        severity = (json['severity'] as num).toInt(),
        description = json['description'] as String,
        latitude = (json['latitude'] as num).toDouble(),
        longitude = (json['longitude'] as num).toDouble(),
        status = json['status'] as String;

  final String id;
  final String category;
  final int severity;
  final String description;
  final double latitude;
  final double longitude;
  final String status;
}

class RoadMapScreen extends StatefulWidget {
  const RoadMapScreen({super.key});

  @override
  State<RoadMapScreen> createState() => _RoadMapScreenState();
}

class _RoadMapScreenState extends State<RoadMapScreen> {
  MapLibreMapController? _map;
  StreamSubscription<Position>? _positionSubscription;
  Position? _position;
  List<RoadHazard> _hazards = [];
  List<Symbol> _symbols = [];
  String? _error;
  bool _loadingHazards = false;
  bool _reloadHazardsAfterCurrent = false;
  bool _forceHazardReloadAfterCurrent = false;
  DateTime? _lastHazardRefreshAt;
  String? _userId;

  @override
  void initState() {
    super.initState();
    _loadAnonymousUserId();
  }

  Future<void> _loadAnonymousUserId() async {
    final preferences = await SharedPreferences.getInstance();
    final id = preferences.getString('rcmca_anonymous_user_id') ?? const Uuid().v4();
    await preferences.setString('rcmca_anonymous_user_id', id);
    if (mounted) setState(() => _userId = id);
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _onMapCreated(MapLibreMapController controller) async {
    _map = controller;
    await _loadHazards();
  }

  Future<void> _loadHazards({bool force = false}) async {
    final map = _map;
    if (map == null) return;
    if (_loadingHazards) {
      _reloadHazardsAfterCurrent = true;
      _forceHazardReloadAfterCurrent |= force;
      return;
    }
    final lastRefresh = _lastHazardRefreshAt;
    if (!force && lastRefresh != null && DateTime.now().difference(lastRefresh) < const Duration(seconds: 15)) {
      return;
    }
    _loadingHazards = true;
    try {
      final visibleBounds = await map.getVisibleRegion();
      final bounds = visibleBounds;
      final uri = Uri.parse('$apiBase/api/v1/issues').replace(queryParameters: {
        'south': bounds.southwest.latitude.toString(),
        'west': bounds.southwest.longitude.toString(),
        'north': bounds.northeast.latitude.toString(),
        'east': bounds.northeast.longitude.toString(),
        'limit': '500',
      });
      final response = await http.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) throw Exception('Hazard service returned ${response.statusCode}.');
      final payload = (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
      final hazards = payload.map(RoadHazard.fromJson).toList();
      final old = _symbols;
      _symbols = [];
      if (old.isNotEmpty) await map.removeSymbols(old);
      for (final hazard in hazards) {
        _symbols.add(await map.addSymbol(SymbolOptions(
          geometry: LatLng(hazard.latitude, hazard.longitude),
          iconImage: 'marker-15',
          iconColor: hazard.severity >= 4 ? '#D9342B' : '#E6A323',
          iconSize: hazard.severity >= 4 ? 1.5 : 1.15,
          textField: '${hazard.category.replaceAll('_', ' ')} · ${hazard.severity}/5',
          textOffset: const Offset(0, 1.2),
          textSize: 11,
        )));
      }
      _lastHazardRefreshAt = DateTime.now();
      if (mounted) setState(() { _hazards = hazards; _error = null; });
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not load road hazards: $error');
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

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Road watch · Hyderabad'),
          actions: [IconButton(onPressed: () => _loadHazards(force: true), icon: const Icon(Icons.refresh), tooltip: 'Refresh hazards')],
        ),
        body: Stack(children: [
          MapLibreMap(
            styleString: 'https://demotiles.maplibre.org/style.json',
            initialCameraPosition: const CameraPosition(target: hyderabad, zoom: 12.3),
            myLocationEnabled: true,
            myLocationTrackingMode: MyLocationTrackingMode.none,
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _loadHazards,
            onCameraIdle: () => _loadHazards(force: true),
          ),
          Positioned(left: 16, right: 16, top: 16, child: Card(child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${_hazards.length} active hazards in view', style: Theme.of(context).textTheme.titleMedium),
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
              if (_position != null) Text('GPS ±${_position!.accuracy.toStringAsFixed(0)} m'),
            ]),
          ))),
        ]),
      );
}
