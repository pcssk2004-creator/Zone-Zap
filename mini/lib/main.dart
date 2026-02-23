import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  LatLng? selectedLocation;
  double radius = 500;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Zone Zap"),
        centerTitle: true,
      ),
      body: Column(
  children: [
    Expanded(
      child: GoogleMap(
        initialCameraPosition: const CameraPosition(
          target: LatLng(9.9312, 76.2673),
          zoom: 14,
        ),
        onTap: (LatLng position) {
          setState(() {
            selectedLocation = position;
          });
        },
        markers: selectedLocation != null
            ? {
                Marker(
                  markerId: const MarkerId("selected"),
                  position: selectedLocation!,
                )
              }
            : {},
        circles: selectedLocation != null
            ? {
                Circle(
                  circleId: const CircleId("radius"),
                  center: selectedLocation!,
                  radius: radius,
                  fillColor: Colors.blue.withOpacity(0.3),
                  strokeColor: Colors.blue,
                  strokeWidth: 2,
                )
              }
            : {},
      ),
    ),
    Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          const Text("Select Radius (meters)"),
          Slider(
            min: 100,
            max: 2000,
            divisions: 19,
            value: radius,
            label: radius.round().toString(),
            onChanged: (value) {
              setState(() {
                radius = value;
              });
            },
          ),
        ],
      ),
    ),
  ],
),
    );
  }
}