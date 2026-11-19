import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
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

  Future<void> _openReport() async {
    final issue = await Navigator.of(context).push<RoadHazard>(MaterialPageRoute(builder: (_) => const CaptureScreen()));
    if (issue != null) await _loadHazards();
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
          Positioned(
            right: 16,
            bottom: 24,
            child: FloatingActionButton.extended(
              onPressed: _openReport,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Report'),
            ),
          ),
        ]),
      );
}

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
  void initState() { super.initState(); _initializeCamera(); }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere((item) => item.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      final controller = CameraController(camera, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await controller.initialize();
      if (!mounted) { await controller.dispose(); return; }
      setState(() => _camera = controller);
    } catch (error) { if (mounted) setState(() => _error = 'Camera unavailable: $error'); }
  }

  @override
  void dispose() { _camera?.dispose(); super.dispose(); }

  Future<void> _captureAndSend() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final location = await requestCurrentPosition(LocationAccuracy.bestForNavigation);
      final capturedAt = DateTime.now().toUtc();
      final picture = await camera.takePicture();
      final file = File(picture.path);
      final contentType = picture.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
      final signed = await http.post(Uri.parse('$apiBase/api/v1/uploads/presign'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'file_name': picture.name, 'content_type': contentType}));
      if (signed.statusCode != 200) throw Exception('Upload signing failed (${signed.statusCode}): ${signed.body}');
      final upload = jsonDecode(signed.body) as Map<String, dynamic>;
      final uploaded = await http.put(Uri.parse(upload['upload_url'] as String), headers: Map<String, String>.from(upload['headers'] as Map), body: await file.readAsBytes());
      if (uploaded.statusCode < 200 || uploaded.statusCode >= 300) throw Exception('Image upload failed (${uploaded.statusCode}).');
      final report = await http.post(Uri.parse('$apiBase/api/v1/issues/report'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({
        'category': _category,
        'description': 'Citizen camera report: $_category. Captured ${location.timestamp.toUtc().toIso8601String()} with GPS accuracy ${location.accuracy.toStringAsFixed(1)} m.',
        'latitude': location.latitude,
        'longitude': location.longitude,
        'severity': 3,
        'evidence_image_url': upload['evidence_image_url'],
        'capture_accuracy_m': location.accuracy,
        'capture_heading_degrees': location.heading >= 0 && location.heading < 360 ? location.heading : null,
        'captured_at': capturedAt.toIso8601String(),
      }));
      if (report.statusCode != 201) throw Exception('Report failed (${report.statusCode}): ${report.body}');
      final issue = RoadHazard.fromJson((jsonDecode(report.body) as Map<String, dynamic>)['issue'] as Map<String, dynamic>);
      final vision = http.MultipartRequest('POST', Uri.parse('$apiBase/api/v1/issues/${issue.id}/vision'));
      vision.files.add(await http.MultipartFile.fromPath('image', file.path, contentType: MediaType.parse(contentType)));
      final visionResponse = await vision.send();
      if (visionResponse.statusCode != 202) _error = 'Report saved; vision assessment could not be queued (${visionResponse.statusCode}).';
      if (mounted) Navigator.of(context).pop(issue);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Capture road issue')),
        body: Column(children: [
          Expanded(child: _camera?.value.isInitialized == true ? CameraPreview(_camera!) : Center(child: Text(_error ?? 'Opening camera…'))),
          Padding(padding: const EdgeInsets.all(16), child: Column(children: [
            DropdownButtonFormField<String>(initialValue: _category, decoration: const InputDecoration(labelText: 'Issue type'), items: const [
              DropdownMenuItem(value: 'pothole', child: Text('Pothole')),
              DropdownMenuItem(value: 'waterlogging', child: Text('Waterlogging')),
              DropdownMenuItem(value: 'damaged_surface', child: Text('Damaged road surface')),
              DropdownMenuItem(value: 'open_manhole', child: Text('Open manhole')),
              DropdownMenuItem(value: 'broken_divider', child: Text('Broken divider')),
            ], onChanged: (value) { if (value != null) setState(() => _category = value); }),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _busy ? null : _captureAndSend, icon: const Icon(Icons.camera), label: Text(_busy ? 'Uploading and reporting…' : 'Capture and report'))),
            const SizedBox(height: 4),
            const Text('Location is sampled immediately before capture. Review traffic conditions before using your phone.'),
          ])),
        ]),
      );
}
