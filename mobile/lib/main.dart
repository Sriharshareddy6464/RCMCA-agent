import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

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
        home: const Scaffold(body: Center(child: Text('RCMCA Road Watch'))),
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
