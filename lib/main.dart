import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:hive_flutter/hive_flutter.dart';

// ─────────────────────────────────────────────
// BACKGROUND SERVICE ENTRY POINT
// Must be a top-level function
// ─────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:hive_flutter/hive_flutter.dart';

// ─────────────────────────────────────────────
// BACKGROUND SERVICE ENTRY POINT
// Must be a top-level function
// ─────────────────────────────────────────────

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  await Hive.initFlutter();
  await Hive.openBox('reminders');
  await Hive.openBox('triggered'); // persisted across restarts

  final notifications = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(
    const InitializationSettings(android: androidInit),
  );

  const notifDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'zone_zap_channel',
      'Zone Alerts',
      channelDescription: 'Geofence arrival alerts',
      importance: Importance.max,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      playSound: true,
      enableVibration: true,
    ),
  );

  // ── Shared geofence check logic ──────────────────────────────────────────
  Future<void> checkGeofences(Position position) async {
    final remindersBox = Hive.box('reminders');
    final triggeredBox = Hive.box('triggered');

    for (var key in remindersBox.keys) {
      final r = remindersBox.get(key);
      if (r == null) continue;

      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        (r["lat"] as num).toDouble(),
        (r["lng"] as num).toDouble(),
      );

      final radius = (r["radius"] as num).toDouble();
      final keyStr = key.toString();
      final alreadyTriggered =
          triggeredBox.get(keyStr, defaultValue: false) as bool;

      if (distance <= radius) {
        // Inside zone — notify only once per entry
        if (!alreadyTriggered) {
          await triggeredBox.put(keyStr, true);
          await notifications.show(
            DateTime.now().millisecondsSinceEpoch ~/ 1000,
            "📍 Zone Zap",
            "You're inside the zone: ${r["task"]}",
            notifDetails,
          );
        }
      } else {
        // Outside zone — reset so it triggers again on next entry
        if (alreadyTriggered) {
          await triggeredBox.put(keyStr, false);
        }
      }
    }
  }

  // ── 1. Immediate startup check ───────────────────────────────────────────
  // getPositionStream ONLY fires when the device MOVES.
  // Without this, a user already inside a zone gets no notification
  // until they physically move at least 1m.
  try {
    final initial = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    await checkGeofences(initial);
    service.invoke('locationUpdate', {
      'lat': initial.latitude,
      'lng': initial.longitude,
    });
  } catch (_) {}

  // ── 2. Continuous stream — fires on every 1m of movement ─────────────────
  Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 1,
    ),
  ).listen((position) async {
    await checkGeofences(position);
    service.invoke('locationUpdate', {
      'lat': position.latitude,
      'lng': position.longitude,
    });
  });
}

// ─────────────────────────────────────────────
// INIT BACKGROUND SERVICE
// ─────────────────────────────────────────────

Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'zone_zap_fg',
    'Zone Zap Service',
    description: 'Runs in background to detect geofences',
    importance: Importance.low,
  );

  final flnp = FlutterLocalNotificationsPlugin();
  await flnp
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'zone_zap_fg',
      initialNotificationTitle: 'Zone Zap Active',
      initialNotificationContent: 'Monitoring your geofences...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );

  await service.startService();
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

// ─────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  await Hive.initFlutter();
  await Hive.openBox('reminders');
  await Hive.openBox('triggered');
  await Geolocator.requestPermission();
  await initBackgroundService();
  runApp(const MyApp());
}

// ─────────────────────────────────────────────
// APP
// ─────────────────────────────────────────────

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A14),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C63FF),
          secondary: Color(0xFF00D4AA),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ─────────────────────────────────────────────
// HOME SCREEN
// ─────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  List reminders = [];
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    loadReminders();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> loadReminders() async {
    final box = Hive.box('reminders');
    setState(() {
      reminders = box.keys.map((key) {
        final r = box.get(key);
        return {
          "task": r["task"],
          "location": LatLng(r["lat"], r["lng"]),
          "radius": (r["radius"] as num).toDouble(),
          "key": key,
        };
      }).toList();
    });
  }

  Future<void> saveReminder(Map reminder) async {
    final box = Hive.box('reminders');
    await box.add({
      "task": reminder["task"],
      "lat": (reminder["location"] as LatLng).latitude,
      "lng": (reminder["location"] as LatLng).longitude,
      "radius": reminder["radius"],
    });
  }

  Future<void> _deleteReminder(dynamic key) async {
    final box = Hive.box('reminders');
    final triggeredBox = Hive.box('triggered');
    await box.delete(key);
    await triggeredBox.delete(key.toString()); // clear trigger state too
    loadReminders();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      body: CustomScrollView(
        slivers: [
          // ── App Bar ──
          SliverAppBar(
            expandedHeight: 160,
            pinned: true,
            backgroundColor: const Color(0xFF0A0A14),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF1A1A2E), Color(0xFF0A0A14)],
                  ),
                ),
                child: Stack(
                  children: [
                    // Decorative circles
                    Positioned(
                      top: -30,
                      right: -30,
                      child: Container(
                        width: 180,
                        height: 180,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF6C63FF).withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 20,
                      right: 40,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF00D4AA).withValues(alpha: 0.06),
                        ),
                      ),
                    ),
                    // Title
                    Positioned(
                      bottom: 20,
                      left: 20,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              AnimatedBuilder(
                                animation: _pulseAnimation,
                                builder: (_, __) => Transform.scale(
                                  scale: _pulseAnimation.value,
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFF00D4AA),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'ACTIVE',
                                style: TextStyle(
                                  color: Color(0xFF00D4AA),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 2,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Zone Zap',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          Text(
                            '${reminders.length} active zone${reminders.length != 1 ? 's' : ''}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Body ──
          reminders.isEmpty
              ? SliverFillRemaining(
                  child: _EmptyState(),
                )
              : SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => _ReminderCard(
                        reminder: reminders[i],
                        index: i,
                        onDelete: () => _deleteReminder(reminders[i]["key"]),
                      ),
                      childCount: reminders.length,
                    ),
                  ),
                ),
        ],
      ),

      // ── FAB ──
      floatingActionButton: _AddFAB(
        onAdded: () async {
          final result = await Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (_, a, b) => const AddReminderFlow(),
              transitionsBuilder: (_, a, b, child) => SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 1),
                  end: Offset.zero,
                ).animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
                child: child,
              ),
            ),
          );
          if (result != null) {
            await saveReminder(result);
            loadReminders();
          }
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────
// REMINDER CARD
// ─────────────────────────────────────────────

class _ReminderCard extends StatelessWidget {
  final Map reminder;
  final int index;
  final VoidCallback onDelete;

  const _ReminderCard({
    required this.reminder,
    required this.index,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = [
      const Color(0xFF6C63FF),
      const Color(0xFF00D4AA),
      const Color(0xFFFF6B6B),
      const Color(0xFFFFD93D),
    ];
    final color = colors[index % colors.length];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1A1A2E),
            const Color(0xFF16213E),
          ],
        ),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Icon
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.15),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Icon(Icons.location_on_rounded, color: color, size: 22),
            ),
            const SizedBox(width: 14),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reminder["task"],
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.radar_rounded,
                        size: 13,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${(reminder["radius"] as double).toInt()} m radius',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        Icons.my_location_rounded,
                        size: 13,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${(reminder["location"] as LatLng).latitude.toStringAsFixed(3)}, '
                        '${(reminder["location"] as LatLng).longitude.toStringAsFixed(3)}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Delete
            GestureDetector(
              onTap: onDelete,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFFF6B6B).withValues(alpha: 0.12),
                ),
                child: const Icon(
                  Icons.delete_outline_rounded,
                  color: Color(0xFFFF6B6B),
                  size: 18,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// EMPTY STATE
// ─────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF6C63FF).withValues(alpha: 0.1),
              border: Border.all(
                color: const Color(0xFF6C63FF).withValues(alpha: 0.3),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.radar_rounded,
              size: 48,
              color: Color(0xFF6C63FF),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'No Zones Yet',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap + to create your first\nlocation-based reminder',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 15,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// ADD FAB
// ─────────────────────────────────────────────

class _AddFAB extends StatelessWidget {
  final VoidCallback onAdded;
  const _AddFAB({required this.onAdded});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onAdded,
      child: Container(
        width: 60,
        height: 60,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6C63FF), Color(0xFF9C88FF)],
          ),
          boxShadow: [
            BoxShadow(
              color: Color(0x556C63FF),
              blurRadius: 20,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// ADD REMINDER FLOW (Task name dialog + Map)
// ─────────────────────────────────────────────

class AddReminderFlow extends StatefulWidget {
  const AddReminderFlow({super.key});

  @override
  State<AddReminderFlow> createState() => _AddReminderFlowState();
}

class _AddReminderFlowState extends State<AddReminderFlow> {
  final TextEditingController _taskController = TextEditingController();
  int _step = 0; // 0 = enter task, 1 = pick location

  @override
  Widget build(BuildContext context) {
    return _step == 0 ? _buildTaskStep() : _buildMapStep();
  }

  Widget _buildTaskStep() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF6C63FF).withValues(alpha: 0.15),
              ),
              child: const Icon(
                Icons.edit_location_alt_rounded,
                color: Color(0xFF6C63FF),
                size: 28,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              "What do you\nneed to do?",
              style: TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "We'll remind you when you arrive there.",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 40),
            TextField(
              controller: _taskController,
              autofocus: true,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                hintText: "e.g. Buy groceries",
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.25),
                  fontSize: 18,
                ),
                filled: true,
                fillColor: const Color(0xFF1A1A2E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: Color(0xFF6C63FF),
                    width: 2,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
              ),
              onSubmitted: (_) => _goToMap(),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                onPressed: _goToMap,
                child: const Text(
                  "Pick Location →",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _goToMap() {
    if (_taskController.text.trim().isEmpty) return;
    setState(() => _step = 1);
  }

  Widget _buildMapStep() {
    return MapScreen(
      taskName: _taskController.text.trim(),
      onSave: (result) => Navigator.pop(context, result),
      onBack: () => setState(() => _step = 0),
    );
  }
}

// ─────────────────────────────────────────────
// MAP SCREEN
// ─────────────────────────────────────────────

class MapScreen extends StatefulWidget {
  final String taskName;
  final void Function(Map) onSave;
  final VoidCallback onBack;

  const MapScreen({
    super.key,
    required this.taskName,
    required this.onSave,
    required this.onBack,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  LatLng? selectedLocation;
  double radius = 500;
  final MapController mapController = MapController();
  final TextEditingController searchController = TextEditingController();
  List suggestions = [];
  bool isSearching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    searchController.dispose();
    super.dispose();
  }

  // Kerala center for viewbox bias
  static const double _keralaLat = 10.8505;
  static const double _keralaLng = 76.2711;

  Timer? _debounce;

  Future<void> fetchSuggestions(String query) async {
    _debounce?.cancel();

    if (query.trim().length < 2) {
      setState(() => suggestions = []);
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => isSearching = true);
      try {
        final q = Uri.encodeComponent(query.trim());
        const headers = {
          "User-Agent": "ZoneZapApp/1.0",
          "Accept-Language": "en",
        };

        // Fire both requests in parallel
        final results = await Future.wait([
          // 1️⃣ India-only search with Kerala viewbox bias
          http.get(
            Uri.parse(
              "https://nominatim.openstreetmap.org/search"
              "?q=$q&format=json&countrycodes=in"
              "&viewbox=74.8,8.0,77.6,12.8&bounded=0"
              "&addressdetails=1&limit=7",
            ),
            headers: headers,
          ),
          // 2️⃣ Global search (catches international places if user wants them)
          http.get(
            Uri.parse(
              "https://nominatim.openstreetmap.org/search"
              "?q=$q&format=json&addressdetails=1&limit=5",
            ),
            headers: headers,
          ),
        ]);

        final indiaRaw = results[0].statusCode == 200
            ? json.decode(results[0].body) as List
            : <dynamic>[];
        final globalRaw = results[1].statusCode == 200
            ? json.decode(results[1].body) as List
            : <dynamic>[];

        // Sort India results: Kerala first, then rest of India
        indiaRaw.sort((a, b) {
          final aDist = _distance(
            double.tryParse(a["lat"] ?? "0") ?? 0,
            double.tryParse(a["lon"] ?? "0") ?? 0,
            _keralaLat, _keralaLng,
          );
          final bDist = _distance(
            double.tryParse(b["lat"] ?? "0") ?? 0,
            double.tryParse(b["lon"] ?? "0") ?? 0,
            _keralaLat, _keralaLng,
          );
          return aDist.compareTo(bDist);
        });

        // Merge: India results first, then global non-India results appended
        final seenIds = <String>{};
        final merged = <dynamic>[];

        for (final r in indiaRaw) {
          final id = r["place_id"]?.toString() ?? "";
          if (seenIds.add(id)) merged.add(r);
        }
        for (final r in globalRaw) {
          final id = r["place_id"]?.toString() ?? "";
          final country = (r["address"]?["country_code"] ?? "") as String;
          // Only add non-India global results (India ones already included above)
          if (country != "in" && seenIds.add(id)) merged.add(r);
        }

        setState(() => suggestions = merged.take(8).toList());
      } catch (_) {
        setState(() => suggestions = []);
      } finally {
        setState(() => isSearching = false);
      }
    });
  }

  // Simple Euclidean distance for sorting (no need for precise Haversine here)
  double _distance(double lat1, double lng1, double lat2, double lng2) {
    final dlat = lat1 - lat2;
    final dlng = lng1 - lng2;
    return dlat * dlat + dlng * dlng;
  }

  // Format address nicely: "Place, District, State" instead of full long string
  String _formatPlace(Map place) {
    final addr = place["address"] as Map? ?? {};
    final parts = <String>[];

    final name = place["name"] as String? ?? "";
    final suburb = addr["suburb"] as String? ?? addr["neighbourhood"] as String? ?? "";
    final city = addr["city"] as String?
        ?? addr["town"] as String?
        ?? addr["village"] as String?
        ?? addr["county"] as String?
        ?? "";
    final district = addr["state_district"] as String? ?? "";
    final state = addr["state"] as String? ?? "";

    if (name.isNotEmpty) parts.add(name);
    if (suburb.isNotEmpty && suburb != name) parts.add(suburb);
    if (city.isNotEmpty && city != name) parts.add(city);
    if (district.isNotEmpty && district != city) parts.add(district);
    if (state.isNotEmpty) parts.add(state);

    return parts.isEmpty
        ? (place["display_name"] as String? ?? "")
        : parts.join(", ");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      body: Stack(
        children: [
          // ── Full-screen Map ──
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: const LatLng(9.9312, 76.2673),
              initialZoom: 13,
              onTap: (_, point) {
                setState(() {
                  selectedLocation = point;
                  suggestions = [];
                  searchController.clear();
                });
              },
            ),
            children: [
              TileLayer(
                urlTemplate:
                    "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png",
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.example.zonezap',
              ),
              if (selectedLocation != null)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: selectedLocation!,
                      radius: radius,
                      useRadiusInMeter: true,
                      color: const Color(0xFF6C63FF).withValues(alpha: 0.18),
                      borderColor: const Color(0xFF6C63FF).withValues(alpha: 0.7),
                      borderStrokeWidth: 2,
                    ),
                  ],
                ),
              if (selectedLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: selectedLocation!,
                      width: 44,
                      height: 44,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF6C63FF).withValues(alpha: 0.2),
                        ),
                        child: const Icon(
                          Icons.location_pin,
                          color: Color(0xFF6C63FF),
                          size: 36,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // ── Top overlay ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 8,
                left: 16,
                right: 16,
                bottom: 12,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF0A0A14).withValues(alpha: 0.95),
                    const Color(0xFF0A0A14).withValues(alpha: 0.0),
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      GestureDetector(
                        onTap: widget.onBack,
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.1),
                          ),
                          child: const Icon(
                            Icons.arrow_back_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.taskName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'Tap map or search to set location',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Search bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: TextField(
                        controller: searchController,
                        onChanged: fetchSuggestions,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: "Search location...",
                          hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                          suffixIcon: isSearching
                              ? Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white.withValues(alpha: 0.5),
                                    ),
                                  ),
                                )
                              : null,
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Suggestions
                  if (suggestions.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      constraints: const BoxConstraints(maxHeight: 200),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: suggestions.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                        itemBuilder: (_, i) {
                          final place = suggestions[i] as Map;
                          final title = _formatPlace(place);
                          final addr = place["address"] as Map? ?? {};
                          final countryCode = (addr["country_code"] ?? "") as String;
                          final isIndia = countryCode == "in";
                          final subtitle = [
                            addr["state_district"] ?? addr["county"] ?? "",
                            addr["state"] ?? "",
                            if (!isIndia) addr["country"] ?? "",
                          ].where((s) => (s as String).isNotEmpty).join(", ");

                          return ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.location_on_rounded,
                              size: 18,
                              color: Color(0xFF6C63FF),
                            ),
                            title: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: subtitle.isNotEmpty
                                ? Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.45),
                                      fontSize: 11,
                                    ),
                                  )
                                : null,
                            trailing: !isIndia
                                ? Text(
                                    addr["country"] ?? "",
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.3),
                                      fontSize: 10,
                                    ),
                                  )
                                : null,
                            onTap: () {
                              final lat = double.parse(place["lat"]);
                              final lng = double.parse(place["lon"]);
                              final point = LatLng(lat, lng);
                              setState(() {
                                selectedLocation = point;
                                suggestions = [];
                                searchController.text = title;
                              });
                              mapController.move(point, 15);
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),

          // ── Bottom panel ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    20,
                    20,
                    MediaQuery.of(context).padding.bottom + 20,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0A14).withValues(alpha: 0.92),
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Drag handle
                      Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Alert Radius",
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                "${radius.toInt()} meters",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6C63FF).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(0xFF6C63FF).withValues(alpha: 0.3),
                              ),
                            ),
                            child: Text(
                              selectedLocation != null
                                  ? "📍 Location set"
                                  : "Tap map to pin",
                              style: const TextStyle(
                                color: Color(0xFF6C63FF),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 4,
                          activeTrackColor: const Color(0xFF6C63FF),
                          inactiveTrackColor:
                              Colors.white.withValues(alpha: 0.1),
                          thumbColor: const Color(0xFF6C63FF),
                          overlayColor: const Color(0xFF6C63FF).withValues(alpha: 0.2),
                        ),
                        child: Slider(
                          min: 100,
                          max: 2000,
                          divisions: 19,
                          value: radius,
                          onChanged: (v) => setState(() => radius = v),
                        ),
                      ),
                      const SizedBox(height: 12),

                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: selectedLocation != null
                                ? const Color(0xFF6C63FF)
                                : Colors.white.withValues(alpha: 0.1),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                          onPressed: selectedLocation == null
                              ? null
                              : () {
                                  widget.onSave({
                                    "task": widget.taskName,
                                    "location": selectedLocation,
                                    "radius": radius,
                                  });
                                },
                          child: Text(
                            selectedLocation != null
                                ? "Save Reminder"
                                : "Pick a Location First",
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}