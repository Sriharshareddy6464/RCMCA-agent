import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:material_ui/material_ui.dart';
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
  Line? _routeLine;
  String? _error;
  bool _navigationActive = false;
  bool _loadingHazards = false;
  bool _reloadHazardsAfterCurrent = false;
  bool _forceHazardReloadAfterCurrent = false;
  DateTime? _lastHazardRefreshAt;
  final Set<String> _promptedIssueIds = {};
  String? _userId;
  final TextEditingController _destinationLat = TextEditingController(text: '17.4435');
  final TextEditingController _destinationLon = TextEditingController(text: '78.3772');

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
    _destinationLat.dispose();
    _destinationLon.dispose();
    super.dispose();
  }

  Future<void> _startLocation() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) throw Exception('Turn on device location to use road alerts.');
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw Exception('Location permission is needed for reports and nearby alerts.');
      }
      if (_navigationActive && permission != LocationPermission.always) {
        permission = await Geolocator.requestPermission();
        if (permission != LocationPermission.always) {
          if (mounted) {
            await showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Allow background location'),
                content: const Text('Allow background location to receive hazard prompts while RCMCA navigation is active and the app is not open. Without it, prompts are limited to when the app is in use. You can change this in app settings.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
                  FilledButton(onPressed: () async { await Geolocator.openAppSettings(); if (context.mounted) Navigator.pop(context); }, child: const Text('Open settings')),
                ],
              ),
            );
          }
        }
      }
      final settings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
              foregroundNotificationConfig: _navigationActive
                  ? const ForegroundNotificationConfig(
                      notificationTitle: 'RCMCA navigation is active',
                      notificationText: 'Checking nearby road hazards while you travel.',
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
      _positionSubscription = Geolocator.getPositionStream(locationSettings: settings).listen(
        (position) {
          if (!mounted) return;
          setState(() => _position = position);
          if (_map != null) _loadHazards();
          if (_navigationActive) _checkNearbyHazards(position);
        },
        onError: (Object error) {
          if (mounted) setState(() => _error = 'Location stream failed: $error');
        },
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    }
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
      final position = _position;
      final bounds = _navigationActive && position != null
          ? LatLngBounds(
              southwest: LatLng(position.latitude - 0.012, position.longitude - 0.015),
              northeast: LatLng(position.latitude + 0.012, position.longitude + 0.015),
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
      if (_navigationActive && _position != null) _checkNearbyHazards(_position!);
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

  Future<void> _planRoute() async {
    try {
      final origin = _position ?? await requestCurrentPosition(LocationAccuracy.high);
      if (mounted) setState(() => _position = origin);
      final response = await http.post(
        Uri.parse('$apiBase/api/v1/routes/plan'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'origin': {'latitude': origin.latitude, 'longitude': origin.longitude},
          'destination': {
            'latitude': double.parse(_destinationLat.text),
            'longitude': double.parse(_destinationLon.text),
          },
        }),
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) throw Exception('Route service returned ${response.statusCode}.');
      final result = jsonDecode(response.body) as Map<String, dynamic>;
      final coordinates = (result['geometry']['coordinates'] as List)
          .map((point) => LatLng((point[1] as num).toDouble(), (point[0] as num).toDouble()))
          .toList();
      final map = _map;
      if (map == null || coordinates.length < 2) return;
      if (_routeLine != null) await map.removeLine(_routeLine!);
      _routeLine = await map.addLine(LineOptions(
        geometry: coordinates,
        lineColor: '#147D64',
        lineWidth: 5,
        lineOpacity: 0.9,
      ));
      setState(() => _navigationActive = true);
      await _startLocation();
      final distanceKm = (result['distance_m'] as num).toDouble() / 1000;
      _message('${distanceKm.toStringAsFixed(1)} km · ${(result['hazards'] as List).length} hazards on this route${result['avoided_severe_hazards'] == true ? ' · severe hazard avoided' : ''}');
    } catch (error) {
      _message('Could not plan route: $error');
    }
  }

  void _checkNearbyHazards(Position position) {
    for (final hazard in _hazards) {
      if (_promptedIssueIds.contains(hazard.id)) continue;
      final distance = Geolocator.distanceBetween(position.latitude, position.longitude, hazard.latitude, hazard.longitude);
      if (distance <= 50) {
        _promptedIssueIds.add(hazard.id);
        _showVerification(hazard);
        break;
      }
    }
  }

  Future<void> _showVerification(RoadHazard hazard) async {
    if (!mounted) return;
    final vote = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Road condition check'),
        content: Text('${hazard.category.replaceAll('_', ' ')} reported nearby. Is it still damaged?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'RESOLVED'), child: const Text('Road fixed')),
          FilledButton(onPressed: () => Navigator.pop(context, 'CONFIRM'), child: const Text('Still damaged')),
        ],
      ),
    );
    if (vote == null) return;
    final userId = _userId;
    if (userId == null) {
      _message('Could not load your anonymous device identity. Try again.');
      return;
    }
    try {
      final response = await http.post(
        Uri.parse('$apiBase/api/v1/issues/${hazard.id}/verify'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': userId, 'vote_type': vote}),
      );
      if (response.statusCode != 200) throw Exception('Verification returned ${response.statusCode}.');
      await _loadHazards();
    } catch (error) {
      _message('Could not submit verification: $error');
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
          Positioned(left: 16, right: 16, bottom: 18, child: Card(child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(child: TextField(controller: _destinationLat, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Destination latitude'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: _destinationLon, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Longitude'))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: FilledButton.icon(onPressed: _planRoute, icon: const Icon(Icons.alt_route), label: Text(_navigationActive ? 'Refresh safer route' : 'Plan safer route'))),
                const SizedBox(width: 10),
                FilledButton.tonalIcon(onPressed: _openReport, icon: const Icon(Icons.camera_alt), label: const Text('Report')),
              ]),
              if (_navigationActive) TextButton(onPressed: () { setState(() => _navigationActive = false); _startLocation(); }, child: const Text('End navigation checks')),
            ]),
          ))),
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
