import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('reminders');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List reminders = [];
  final notifications = FlutterLocalNotificationsPlugin();
  Set triggered = {};

  @override
  void initState() {
    super.initState();
    loadReminders();
    requestPermission();
    initNotification();
    startTracking();
  }

  Future<void> initNotification() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidInit);
    await notifications.initialize(settings);
  }

  Future<void> requestPermission() async {
    await Geolocator.requestPermission();
  }

  Future<void> loadReminders() async {
    final box = Hive.box('reminders');
    setState(() {
      reminders = box.keys.map((key) {
        final r = box.get(key);
        return {
          "task": r["task"],
          "location": LatLng(r["lat"], r["lng"]),
          "radius": r["radius"],
          "key": key,
        };
      }).toList();
    });
  }

  Future<void> saveReminder(Map reminder) async {
    final box = Hive.box('reminders');
    await box.add({
      "task": reminder["task"],
      "lat": reminder["location"].latitude,
      "lng": reminder["location"].longitude,
      "radius": reminder["radius"],
    });
  }

  void startTracking() async {
    Position current = await Geolocator.getCurrentPosition();
    checkLocation(current);

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen((position) {
      checkLocation(position);
    });
  }

  void checkLocation(Position position) async {
    for (var r in reminders) {
      double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        r["location"].latitude,
        r["location"].longitude,
      );

      if (distance <= r["radius"]) {
        if (!triggered.contains(r["key"])) {
          triggered.add(r["key"]);

          const androidDetails = AndroidNotificationDetails(
            'zone',
            'zone alerts',
            importance: Importance.max,
            priority: Priority.high,
          );

          await notifications.show(
            DateTime.now().millisecondsSinceEpoch ~/ 1000,
            "Zone Zap",
            "You reached: ${r["task"]}",
            const NotificationDetails(android: androidDetails),
          );
        }
      } else {
        triggered.remove(r["key"]);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Zone Zap")),
      body: reminders.isEmpty
          ? const Center(child: Text("No reminders yet"))
          : ListView.builder(
              itemCount: reminders.length,
              itemBuilder: (_, i) {
                return ListTile(
                  title: Text(reminders[i]["task"]),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () async {
                      final box = Hive.box('reminders');
                      await box.delete(reminders[i]["key"]);
                      loadReminders();
                    },
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () async {
          TextEditingController c = TextEditingController();

          final task = await showDialog<String>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text("Enter Task"),
              content: TextField(controller: c),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("Cancel")),
                ElevatedButton(
                    onPressed: () => Navigator.pop(context, c.text),
                    child: const Text("Next")),
              ],
            ),
          );

          if (task != null && task.trim().isNotEmpty) {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MapScreen(taskName: task),
              ),
            );

            if (result != null) {
              await saveReminder(result);
              loadReminders();
            }
          }
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────
// MAP SCREEN
// ─────────────────────────────────────────────

class MapScreen extends StatefulWidget {
  final String taskName;
  const MapScreen({super.key, required this.taskName});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  LatLng? selectedLocation;
  double radius = 500;

  final MapController mapController = MapController();
  final TextEditingController searchController = TextEditingController();

  List suggestions = [];

  Future<void> fetchSuggestions(String query) async {
    if (query.isEmpty) {
      setState(() => suggestions = []);
      return;
    }

    final res = await http.get(
      Uri.parse(
          "https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(query)}&format=json&limit=5"),
      headers: {"User-Agent": "ZoneZap"},
    );

    final data = json.decode(res.body);
    setState(() => suggestions = data);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.taskName)),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(10),
            child: TextField(
              controller: searchController,
              onChanged: fetchSuggestions,
              decoration: const InputDecoration(
                hintText: "Search location...",
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),

          // FIX 1: Search suggestions dropdown
          if (suggestions.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              margin: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: suggestions.length,
                itemBuilder: (_, i) {
                  final place = suggestions[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.location_on, size: 18),
                    title: Text(
                      place["display_name"] ?? "",
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    onTap: () {
                      final lat = double.parse(place["lat"]);
                      final lng = double.parse(place["lon"]);
                      final point = LatLng(lat, lng);

                      setState(() {
                        selectedLocation = point;
                        suggestions = [];
                        searchController.text = place["display_name"] ?? "";
                      });

                      mapController.move(point, 15);
                    },
                  );
                },
              ),
            ),

          // Map
          Expanded(
            child: FlutterMap(
              mapController: mapController,
              options: MapOptions(
                initialCenter: const LatLng(9.9312, 76.2673),
                initialZoom: 13,
                onTap: (_, point) {
                  setState(() {
                    selectedLocation = point;
                    suggestions = [];
                  });
                },
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                  userAgentPackageName: 'com.example.mini',
                ),

                // FIX 2: Geofence circle
                if (selectedLocation != null)
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: selectedLocation!,
                        radius: radius,
                        useRadiusInMeter: true,
                        color: Colors.blue.withOpacity(0.2),
                        borderColor: Colors.blue,
                        borderStrokeWidth: 2,
                      ),
                    ],
                  ),

                // FIX 3: Pin marker
                if (selectedLocation != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: selectedLocation!,
                        width: 40,
                        height: 40,
                        child: const Icon(
                          Icons.location_pin,
                          color: Colors.red,
                          size: 40,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),

          // Radius slider
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                Text(
                  "Radius: ${radius.toInt()} m",
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                Slider(
                  min: 100,
                  max: 2000,
                  divisions: 19,
                  value: radius,
                  label: "${radius.toInt()} m",
                  onChanged: (v) => setState(() => radius = v),
                ),
              ],
            ),
          ),

          // FIX 4: Save button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.save),
                label: const Text("Save Reminder"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: selectedLocation == null
                    ? null
                    : () {
                        Navigator.pop(context, {
                          "task": widget.taskName,
                          "location": selectedLocation,
                          "radius": radius,
                        });
                      },
              ),
            ),
          ),
        ],
      ),
    );
  }
}