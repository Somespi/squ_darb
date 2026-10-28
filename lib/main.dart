import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:aptabase_flutter/aptabase_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_animations/flutter_map_animations.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:ming_cute_icons/ming_cute_icons.dart';
import 'package:smooth_border/smooth_border.dart';
import 'package:solar_icons/solar_icons.dart';

const String _aptabaseAppKey = 'A-EU-4822936444';
const String _campusRemoteUrl =
    'https://raw.githubusercontent.com/Somespi/squ_darb/refs/heads/master/assets/data/campus.json';
const String _campusCacheKey = 'campus_json_cache';

class CampusData {
  final int version;
  final Map<String, dynamic> places;
  const CampusData(this.version, this.places);
}

CampusData? parseCampus(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final version = decoded['version'];
    if (version is! int) return null;

    final places = Map<String, dynamic>.from(decoded)..remove('version');
    if (places.isEmpty) return null;
    for (final b in places.values) {
      if (b is! Map || b['lat'] is! num || b['lon'] is! num) return null;
    }
    return CampusData(version, places);
  } catch (_) {
    return null;
  }
}

Future<CampusData> loadCampusLocal() async {
  final bundled = parseCampus(
    await rootBundle.loadString('assets/data/campus.json'),
  )!;
  try {
    final prefs = await SharedPreferences.getInstance();
    final cachedRaw = prefs.getString(_campusCacheKey);
    if (cachedRaw != null) {
      final cached = parseCampus(cachedRaw);
      if (cached != null && cached.version > bundled.version) return cached;
    }
  } catch (e) {
    debugPrint('campus cache read failed: $e');
  }
  return bundled;
}


Future<CampusData?> fetchCampusUpdate(int currentVersion) async {
  try {
    final res = await http
        .get(Uri.parse(_campusRemoteUrl))
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;

    final raw = utf8.decode(res.bodyBytes); 
    final remote = parseCampus(raw);
    if (remote == null || remote.version <= currentVersion) return null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_campusCacheKey, raw);
    return remote;
  } catch (e) {
    debugPrint('campus update check failed: $e');
    return null;
  }
}

class Analytics {
  static bool _ready = false;

  static Future<void> init() async {
    try {
      await Aptabase.init(_aptabaseAppKey);
      _ready = true;
    } catch (e) {
      debugPrint('analytics init failed: $e');
    }
  }

  static void log(String event, [Map<String, dynamic>? props]) {
    debugPrint('analytics: $event ${props ?? {}}');
    if (!_ready) return;
    try {
      Aptabase.instance.trackEvent(event, props).catchError((Object e) {
        debugPrint('analytics error: $e');
      });
    } catch (e) {
      debugPrint('analytics error: $e');
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Analytics.init();
  runApp(const DarbApp());
}

class DarbApp extends StatelessWidget {
  const DarbApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Darb',
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'thmanyahsans',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF008577)),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: DarbMapPage(),
      ),
    );
  }
}

class DarbMapPage extends StatefulWidget {
  const DarbMapPage({super.key});

  @override
  State<DarbMapPage> createState() => _DarbMapPageState();
}

typedef RouteResult = (List<dynamic>, dynamic, dynamic);

class _DarbMapPageState extends State<DarbMapPage>
    with TickerProviderStateMixin {
  static const LatLng _initialCenter = LatLng(23.5913, 58.1722);
  static const EdgeInsets _routePadding = EdgeInsets.fromLTRB(40, 160, 40, 120);

  bool _isDaroobStaring = false;
  Timer? _animationTimer;
  final math.Random _random = math.Random();

  
  Timer? _searchLogTimer;

  final MapController _mapController = MapController();
  late final AnimatedMapController _animated = AnimatedMapController(
    vsync: this,
    mapController: _mapController,
    duration: const Duration(milliseconds: 800),
    curve: Curves.easeInOutCubic,
  );

  late final AnimationController _routeAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  List<double> _routeCumulative = []; 

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  Marker? _currentMarker;

  StreamSubscription<Position>? _positionSubscription;

  LatLng? _currentPosition;

  List<LatLng> routePoints = [];

  bool _mapReady = false;
  bool _hasCentered = false;

  Map<String, dynamic> campusPlaces = {};

  @override
  void initState() {
    super.initState();
    Analytics.log('app_started');
    _startLocationTracking();
    _initCampusData();
    _searchFocusNode.addListener(_onFocusChange);
  }

  Future<void> _initCampusData() async {
    final local = await loadCampusLocal();
    if (!mounted) return;
    setState(() {
      campusPlaces = local.places;
    });

    final update = await fetchCampusUpdate(local.version);
    if (update == null || !mounted) return;
    setState(() {
      campusPlaces = update.places;
    });
    Analytics.log('campus_data_updated', {
      'from': local.version,
      'to': update.version,
    });
  }

  void _onFocusChange() {
    if (_searchFocusNode.hasFocus) {
      _startStaring();
      if (_searchController.text.trim().isNotEmpty && !_resultsOpen) {
        setState(() => _resultsOpen = true);
      }
    } else {
      _animationTimer?.cancel();
      _animationTimer = null;

      if (mounted) {
        setState(() {
          _isDaroobStaring = false;
        });
      }
    }
  }

  void _startStaring() {
    _animationTimer?.cancel();

    void scheduleNext() {
      final seconds = 5 + _random.nextInt(3);

      _animationTimer = Timer(Duration(seconds: seconds), () {
        if (!mounted || !_searchFocusNode.hasFocus) return;

        setState(() {
          _isDaroobStaring = !_isDaroobStaring;
        });

        scheduleNext();
      });
    }

    scheduleNext();
  }

  Future<void> _startLocationTracking() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        Analytics.log('location_denied', {'reason': 'service_disabled'});
        _showMessage('يرجى تفعيل خدمة الموقع في هاتفك.');
        return;
      }

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        Analytics.log('location_denied', {
          'reason': permission == LocationPermission.deniedForever
              ? 'denied_forever'
              : 'denied',
        });
        _showMessage('يرجى السماح للتطبيق بالوصول إلى موقعك.');
        return;
      }

      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
          ),
        );

        _updatePosition(position);
      } catch (e) {
        debugPrint('تعذر الحصول على الموقع الأولي: $e');
      }

      await _positionSubscription?.cancel();

      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 2,
            ),
          ).listen(
            _updatePosition,
            onError: (Object error) {
              debugPrint('خطأ في تتبع الموقع: $error');
            },
          );
    } catch (e) {
      debugPrint('خطأ في تهيئة الموقع: $e');
      Analytics.log('location_error');
      _showMessage('تعذر الوصول إلى موقعك.');
    }
  }

  void _updatePosition(Position position) {
    if (!mounted) return;

    final location = LatLng(position.latitude, position.longitude);

    setState(() {
      _currentPosition = location;
    });

    if (_mapReady && !_hasCentered) {
      _hasCentered = true;
      
      _animated.animateTo(dest: location, zoom: 18);
    }
  }

  void _onMapReady() {
    _mapReady = true;

    final location = _currentPosition;

    if (location != null && !_hasCentered) {
      _hasCentered = true;
      _mapController.move(location, 18); 
    }
  }

  void _goToCurrentLocation() {
    final position = _currentPosition;

    if (position == null) {
      _showMessage('جارٍ تحديد موقعك، يرجى الانتظار...');
      return;
    }

    _animated.animateTo(dest: position, zoom: 18);
  }

  void _fitRoute(List<LatLng> points) {
    if (points.length < 2) return;
    _animated.animatedFitCamera(
      cameraFit: CameraFit.coordinates(
        coordinates: points,
        padding: _routePadding,
        maxZoom: 18,
      ),
    );
  }

  void _applyRoute(List<dynamic> coords) {
    final pts = _toLatLngs(coords);

    const dist = Distance();
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum.last + dist(pts[i - 1], pts[i]));
    }

    _routeAnim.stop();
    setState(() {
      routePoints = pts;
      _routeCumulative = cum;
    });

    _fitRoute(pts);

    final ms = (600 + cum.last * 11).clamp(1000, 4000).round();
    _routeAnim.duration = Duration(milliseconds: ms);
    _routeAnim.forward(from: 0);
  }

  List<LatLng> _visibleRoute(double t) {
    if (routePoints.length < 2 ||
        _routeCumulative.length != routePoints.length) {
      return routePoints;
    }
    if (t >= 1) return routePoints;

    final target = _routeCumulative.last * t;
    final out = <LatLng>[routePoints.first];

    for (var i = 1; i < routePoints.length; i++) {
      if (_routeCumulative[i] <= target) {
        out.add(routePoints[i]);
      } else {
        final segLen = _routeCumulative[i] - _routeCumulative[i - 1];
        final f = segLen == 0
            ? 0.0
            : (target - _routeCumulative[i - 1]) / segLen;
        final a = routePoints[i - 1];
        final b = routePoints[i];
        out.add(
          LatLng(
            a.latitude + (b.latitude - a.latitude) * f,
            a.longitude + (b.longitude - a.longitude) * f,
          ),
        );
        break;
      }
    }
    return out;
  }

  void _clearMarkerAndRoute() {
    Analytics.log('marker_cleared', {'had_route': routePoints.isNotEmpty});
    _routeAnim.stop();
    setState(() {
      _currentMarker = null;
      routePoints = [];
    });
    final position = _currentPosition;
    if (position != null) {
      _animated.animateTo(dest: position, zoom: 18);
    }
  }

  List<Map<String, dynamic>> searchResults = [];

  bool _resultsOpen = false;

  void searchCampus(String query) {
    final results = CampusSearch(campusPlaces)
        .search(query)
        .map(
          (result) => <String, dynamic>{
            'id': result.id,
            'name': result.name,
            'type': result.isRoom ? 'room' : 'building',
            'building_id': result.buildingId,
            'further_instructions': result.isRoom
                ? result.room!['further_instructions']
                : result.building['further_instructions'],
            if (result.isRoom) ...{
              'floor': result.room?['floor'],
              'buildingName':
                  result.building['name_display']?.toString() ??
                  result.buildingId,
            },
            'building': result.building,
            'icon': resolvePlaceIcon(
              cacheKey: '${result.buildingId}/${result.id}/${result.name}',
              isRoom: result.isRoom,
              name: result.name,
              keywords: _readKeywords(
                result.isRoom
                    ? result.room!['search_keywords']
                    : result.building['search_keywords'],
              ),
              explicitKey:
                  (result.isRoom
                          ? result.room!['icon']
                          : result.building['icon'])
                      ?.toString(),
            ),
          },
        )
        .toList();

    setState(() {
      searchResults = results;
      _resultsOpen = query.trim().isNotEmpty;
    });
    _logSearch(query);
  }

  
  
  void _logSearch(String query) {
    _searchLogTimer?.cancel();

    final q = query.trim();
    if (q.isEmpty) return;

    
    final safeQuery = q.length > 50 ? q.substring(0, 50) : q;

    _searchLogTimer = Timer(const Duration(milliseconds: 800), () {
      Analytics.log(searchResults.isEmpty ? 'search_no_results' : 'search', {
        'query': safeQuery,
        'result_count': searchResults.length,
      });
    });
  }

  List<Marker> createMapMarkersForBuildings() {
    final List<Marker> markers = [];
    final Map<String, Color> markerColors = {
      "college": const Color(0xFFC9826B),
      "teaching": const Color(0xFFD6B58C),
      "library": const Color(0xFF8F9B83),
      "research_center": const Color(0xFFB7A5C7),
      "other": const Color(0xFF7F9C9A),
    };

    campusPlaces.forEach((key, building) {
      markers.add(
        Marker(
          point: LatLng(building['lat'], building['lon']),
          width: 40.0,
          height: 40.0,
          rotate: true,
          child: CircleAvatar(
            backgroundColor: markerColors[building['genre'] as String],
            radius: 30,
            child: const Icon(Icons.school, size: 20, color: Colors.white),
          ),
        ),
      );
    });

    return markers;
  }

  Future<RouteResult> getRoute(
    LatLng startPoint,
    LatLng endPoint, {
    String method = 'driving',
  }) async {
    
    
    
    final base = method == 'walking'
        ? 'https://routing.openstreetmap.de/routed-foot/route/v1/driving'
        : 'https://router.project-osrm.org/route/v1/driving';
    final url =
        '$base/'
        '${startPoint.longitude},${startPoint.latitude};'
        '${endPoint.longitude},${endPoint.latitude}?overview=full&geometries=geojson';
    final response = await http.get(Uri.parse(url));

    final data = jsonDecode(response.body);
    final List coordinates = data['routes'][0]['geometry']['coordinates'];
    return (
      coordinates,
      data['routes'][0]['legs'][0]['duration'],
      data['routes'][0]['legs'][0]['distance'],
    );
  }

  List<LatLng> _toLatLngs(List<dynamic> coords) => coords
      .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
      .toList();

  Future<void> _showRoute(LatLng from, LatLng to, String method) async {
    try {
      final route = await getRoute(from, to, method: method);
      if (!mounted) return;
      _applyRoute(route.$1);
    } catch (e) {
      debugPrint('تعذر جلب المسار: $e');
      Analytics.log('route_failed', {'mode': method, 'stage': 'apply'});
      _showMessage('تعذر جلب المسار.');
    }
  }

  Marker createMapMarkerForBuilding(String id) {
    final building = campusPlaces[id];
    return Marker(
      point: LatLng(building['lat'], building['lon']),
      width: 40.0,
      height: 40.0,
      rotate: true,
      child: Stack(
        children: [
          Image.asset(
            'assets/images/daroob_sitting_faceless.png',
            fit: BoxFit.contain,
            filterQuality: FilterQuality.none,
          ),
          const Positioned(
            left: 12,
            bottom: 12.5,
            child: Icon(
              MingCuteIcons.mgc_location_fill,
              color: Color(0xFF002FA7),
              size: 22,
            ),
          ),
        ],
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _animated.dispose();
    _routeAnim.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _animationTimer?.cancel();
    _searchLogTimer?.cancel();
    super.dispose();
  }

  Future<void> _onResultTap(Map<String, dynamic> item) async {
    Analytics.log('result_tapped', {
      'id': item['id'],
      'type': item['type'],
      'rank': searchResults.indexOf(item),
    });

    final building = item['building'];
    final target = LatLng(
      (building['lat'] as num).toDouble(),
      (building['lon'] as num).toDouble(),
    );
    final from = _currentPosition;
    if (from == null) {
      _showMessage('جارٍ تحديد موقعك، يرجى الانتظار...');
      return;
    }

    _animated.animateTo(dest: target, zoom: 18);
    _searchController.text = item['name'];
    _searchFocusNode.unfocus();
    setState(() {
      _resultsOpen = false;
      _currentMarker = createMapMarkerForBuilding(item['building_id']);
    });
    final RouteResult ridingRoute;
    try {
      ridingRoute = await getRoute(from, target);
    } catch (e) {
      debugPrint('تعذر جلب المسار: $e');
      Analytics.log('route_failed', {'mode': 'driving', 'stage': 'preview'});
      _showMessage('تعذر جلب المسار.');
      return;
    }
    if (!mounted) return;

    await _showRouteSheet(
      item: item,
      from: from,
      target: target,
      ridingRoute: ridingRoute,
    );
  }

  Future<void> _showRouteSheet({
    required Map<String, dynamic> item,
    required LatLng from,
    required LatLng target,
    required RouteResult ridingRoute,
  }) {
    final isRoom = item['type'] == 'room';

    return showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;

        Widget statCard(IconData icon, String value, String label) {
          return Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.primary.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 22, color: cs.primary),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final buttonShape = RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        );
        const buttonPadding = EdgeInsets.symmetric(vertical: 16);

        final instructions = parseInstructions(item['further_instructions']);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['name'],
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      isRoom
                          ? '${item['buildingName']} • الطابق ${item['floor']}'
                          : 'مبنى',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (instructions.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    ...instructions.map(
                      (line) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: cs.primary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                line,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  color: cs.onSurface.withOpacity(0.8),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      statCard(
                        MingCuteIcons.mgc_ruler_line,
                        (ridingRoute.$3 as num).round().toString(),
                        'متر',
                      ),
                      const SizedBox(width: 12),
                      statCard(
                        MingCuteIcons.mgc_time_duration_line,
                        ((ridingRoute.$2 as num) / 60).ceil().toString(),
                        'دقيقة',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () {
                            Analytics.log('route_requested', {
                              'mode': 'walking',
                              'id': item['id'],
                              'type': item['type'],
                            });
                            Navigator.pop(sheetContext);
                            _showRoute(from, target, 'walking');
                          },
                          icon: const Icon(MingCuteIcons.mgc_walk_line),
                          label: const Text('مشي'),
                          style: FilledButton.styleFrom(
                            padding: buttonPadding,
                            shape: buttonShape,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () {
                            Analytics.log('route_requested', {
                              'mode': 'driving',
                              'id': item['id'],
                              'type': item['type'],
                            });
                            Navigator.pop(sheetContext);
                            _applyRoute(ridingRoute.$1);
                          },
                          icon: const Icon(MingCuteIcons.mgc_car_line),
                          label: const Text('سيارة'),
                          style: FilledButton.styleFrom(
                            padding: buttonPadding,
                            shape: buttonShape,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_resultsOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeSearch();
      },
      child: Scaffold(
        body: SafeArea(
          top: false,
          child: Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _initialCenter,
                  initialZoom: 16,
                  minZoom: 3,
                  maxZoom: 22,
                  onTap: (_, _) => _closeSearch(),
                  onMapReady: _onMapReady,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.squ_navigator',
                    maxNativeZoom: 19,
                  ),
                  const RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution('مساهمو OpenStreetMap'),
                    ],
                  ),

                  if (routePoints.isNotEmpty)
                    AnimatedBuilder(
                      animation: _routeAnim,
                      builder: (context, _) {
                        final t = Curves.easeInOutCubic.transform(
                          _routeAnim.value,
                        );
                        final visible = _visibleRoute(t);
                        if (visible.length < 2) return const SizedBox.shrink();
                        return PolylineLayer(
                          polylines: [
                            Polyline(
                              points: visible,
                              color: Theme.of(context).colorScheme.primary,
                              strokeWidth: 5.0,
                              strokeCap: StrokeCap.round,
                              strokeJoin: StrokeJoin.round,
                            ),
                          ],
                        );
                      },
                    ),

                  MarkerLayer(
                    markers: _currentMarker != null ? [_currentMarker!] : [],
                  ),

                  CurrentLocationLayer(
                    alignPositionOnUpdate: AlignOnUpdate.never,
                    alignDirectionOnUpdate: AlignOnUpdate.never,
                    style: LocationMarkerStyle(
                      marker: const DefaultLocationMarker(
                        child: Icon(Icons.navigation, color: Colors.white),
                      ),
                      markerSize: const Size(40, 40),
                      markerDirection: MarkerDirection.heading,
                    ),
                  ),
                ],
              ),

              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    constraints: const BoxConstraints(maxHeight: 340),
                    child: Material(
                      shape: SmoothRectangleBorder(
                        borderRadius: 24,
                        smoothing: 0.6,
                      ),
                      color: Colors.white,
                      elevation: 8,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Stack(
                            clipBehavior: Clip.hardEdge,
                            alignment: Alignment.bottomCenter,
                            children: [
                              Padding(
                                padding: const EdgeInsetsDirectional.fromSTEB(
                                  16,
                                  4,
                                  12,
                                  4,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _searchController,
                                        focusNode: _searchFocusNode,
                                        onChanged: searchCampus,
                                        onTap: () {
                                          if (_searchController.text
                                                  .trim()
                                                  .isNotEmpty &&
                                              !_resultsOpen) {
                                            setState(() => _resultsOpen = true);
                                          }
                                        },
                                        textInputAction: TextInputAction.search,
                                        textDirection: TextDirection.rtl,
                                        textAlignVertical:
                                            TextAlignVertical.center,
                                        decoration: InputDecoration(
                                          hintText: 'ابحث عن مبنى أو قاعة...',
                                          hintTextDirection: TextDirection.rtl,
                                          border: InputBorder.none,
                                          isDense: true,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                vertical: 12,
                                              ),
                                          prefixIcon: Icon(
                                            MingCuteIcons.mgc_location_fill,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                          prefixIconConstraints:
                                              const BoxConstraints(
                                                minWidth: 40,
                                                minHeight: 40,
                                              ),
                                        ),
                                      ),
                                    ),
                                    AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 250,
                                      ),
                                      reverseDuration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      switchInCurve:
                                          Curves.fastEaseInToSlowEaseOut,
                                      switchOutCurve: Curves.elasticOut,
                                      child: _searchController.text.isNotEmpty
                                          ? IconButton(
                                              key: const ValueKey(
                                                'clear_button',
                                              ),
                                              onPressed: () {
                                                _searchController.clear();
                                                setState(
                                                  () => _resultsOpen = false,
                                                );
                                                _searchFocusNode.requestFocus();
                                              },
                                              icon: const Icon(
                                                MingCuteIcons.mgc_close_line,
                                              ),
                                            )
                                          : const SizedBox(
                                              key: ValueKey('empty'),
                                              width: 48,
                                            ),
                                    ),
                                  ],
                                ),
                              ),

                              AnimatedPositioned(
                                duration: const Duration(milliseconds: 350),
                                curve: Curves.easeOutBack,
                                left: 70,
                                bottom:
                                    _isDaroobStaring &&
                                        _resultsOpen &&
                                        _searchController.text.isNotEmpty
                                    ? 0
                                    : -30,
                                child: Stack(
                                  children: [
                                    Image.asset(
                                      'assets/images/daroob_staring.png',
                                      width: 20 * 1.3,
                                      height: 15.14 * 1.3,
                                      fit: BoxFit.contain,
                                      filterQuality: FilterQuality.none,
                                    ),
                                    Positioned(
                                      bottom: 1,
                                      left: 0,
                                      child:
                                          Image.asset(
                                                'assets/images/daroob_eyes_staring.png',
                                                width: 16.8664803193,
                                                height: 4.50891333832,
                                                fit: BoxFit.contain,
                                                filterQuality:
                                                    FilterQuality.none,
                                              )
                                              .animate(
                                                onPlay: (controller) =>
                                                    controller.repeat(
                                                      reverse: true,
                                                    ),
                                              )
                                              .moveX(
                                                begin: 13 / 4,
                                                end: 13 / 2,
                                                duration: const Duration(
                                                  seconds: 1,
                                                ),
                                                curve: Curves.easeInOutBack,
                                              ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const Divider(height: 1),

                          Flexible(
                            child: AnimatedSize(
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeInOut,
                              alignment: Alignment.topCenter,
                              child:
                                  _resultsOpen &&
                                      _searchController.text.isNotEmpty
                                  ? ListView.builder(
                                      shrinkWrap: true,
                                      itemCount: searchResults.length,
                                      itemBuilder: (listContext, index) {
                                        final item = searchResults[index];
                                        final isRoom = item['type'] == 'room';
                                        if (isRoom && item['floor'] == '0') {
                                          item['floor'] = 'الأرضي';
                                        }
                                        return ListTile(
                                          leading: Icon(iconOfItem(item)),
                                          title: Text(item['name']),
                                          subtitle: Text(
                                            isRoom
                                                ? '${item['buildingName']} • الطابق ${item['floor']}'
                                                : 'مبنى',
                                          ),
                                          onTap: () => _onResultTap(item),
                                        );
                                      },
                                    )
                                  : const SizedBox.shrink(),
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
        ),

        floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
        floatingActionButton: Padding(
          padding: const EdgeInsets.only(bottom: 30),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _currentMarker != null
                  ? FloatingActionButton(
                      heroTag: 'removeMarker',
                      elevation: 5,
                      tooltip: 'احذف العلامة',
                      onPressed: _clearMarkerAndRoute,
                      child: const Icon(SolarIconsBold.mapPointRemove),
                    )
                  : const SizedBox.shrink(),

              const SizedBox(height: 10),
              FloatingActionButton(
                heroTag: 'currentLocationButton',
                elevation: 5,
                tooltip: 'موقعي الحالي',
                onPressed: _goToCurrentLocation,
                child: const Icon(Icons.my_location_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _closeSearch() {
    _searchFocusNode.unfocus();
    if (_resultsOpen) setState(() => _resultsOpen = false);
  }
}

Future<Map<String, dynamic>> loadCampusData() async {
  final jsonString = await rootBundle.loadString('assets/data/campus.json');

  final Map<String, dynamic> data = jsonDecode(jsonString);

  return data;
}



List<String> parseInstructions(dynamic value) {
  if (value == null) return [];
  final parts = value is List
      ? value.map((e) => e.toString())
      : value.toString().split(RegExp(r'[؛;،\n]'));
  return parts
      .map((s) => s.trim().replaceFirst(RegExp(r'^و(?=ال)'), ''))
      .where((s) => s.isNotEmpty)
      .toList();
}

const Map<String, String> _digitMap = {
  '٠': '0',
  '١': '1',
  '٢': '2',
  '٣': '3',
  '٤': '4',
  '٥': '5',
  '٦': '6',
  '٧': '7',
  '٨': '8',
  '٩': '9',
  '۰': '0',
  '۱': '1',
  '۲': '2',
  '۳': '3',
  '۴': '4',
  '۵': '5',
  '۶': '6',
  '۷': '7',
  '۸': '8',
  '۹': '9',
};

String normalizeSearchText(String input) {
  final arabicNormalized = input
      .toLowerCase()
      .replaceAll(RegExp(r'[أإآٱ]'), 'ا')
      .replaceAll('ى', 'ي')
      .replaceAll('ـ', '')
      .replaceAll(
        RegExp(r'[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED]'),
        '',
      );

  final digitsNormalized = arabicNormalized
      .split('')
      .map((char) => _digitMap[char] ?? char)
      .join();

  final cleaned = digitsNormalized.replaceAll(
    RegExp(r'[^a-z0-9\u0621-\u063A\u0641-\u064A\u066E-\u06D3]+'),
    ' ',
  );

  return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class CampusSearchResult {
  final String buildingId;
  final Map<String, dynamic> building;
  final String name;
  final String id;
  final bool isRoom;
  final Map<String, dynamic>? room;
  final int score;

  const CampusSearchResult({
    required this.buildingId,
    required this.building,
    required this.name,
    required this.id,
    required this.isRoom,
    required this.score,
    this.room,
  });
}

List<String> _readKeywords(dynamic value) =>
    value is List ? value.map((item) => item.toString()).toList() : [];

List<String> _buildingFields(
  String buildingId,
  Map<String, dynamic> building,
) => [
  building['name_display']?.toString() ?? buildingId,
  buildingId,
  ..._readKeywords(building['search_keywords']),
];

List<String> _roomFields(String roomId, Map<String, dynamic> room) => [
  room['name_display']?.toString() ?? roomId,
  roomId,
  ..._readKeywords(room['search_keywords']),
];

int _bestScore({
  required String query,
  required List<String> queryTokens,
  required List<String> fields,
}) {
  return fields
      .map(
        (field) => _scoreField(
          query: query,
          queryTokens: queryTokens,
          field: normalizeSearchText(field),
        ),
      )
      .fold(0, math.max);
}

int _scoreField({
  required String query,
  required List<String> queryTokens,
  required String field,
}) {
  if (field.isEmpty) return 0;

  if (field == query) return 100;
  if (field.startsWith(query)) return 80;
  if (field.contains(query)) return 65;

  final fieldTokens = field.split(' ');

  final matchingTokens = queryTokens
      .where(
        (queryToken) => fieldTokens.any(
          (fieldToken) =>
              fieldToken == queryToken || fieldToken.startsWith(queryToken),
        ),
      )
      .length;

  return queryTokens.isEmpty
      ? 0
      : (matchingTokens / queryTokens.length * 50).round();
}

class CampusSearch {
  final Map<String, dynamic> campusData;

  const CampusSearch(this.campusData);

  List<CampusSearchResult> search(String input) {
    final query = normalizeSearchText(input);

    if (query.isEmpty) return [];

    final queryTokens = query.split(' ');

    return campusData.entries.expand((entry) {
      final buildingId = entry.key;
      final building = Map<String, dynamic>.from(entry.value as Map);

      final buildingFields = _buildingFields(buildingId, building);

      final buildingScore = _bestScore(
        query: query,
        queryTokens: queryTokens,
        fields: buildingFields,
      );

      final buildingResult = buildingScore > 0
          ? [
              CampusSearchResult(
                buildingId: buildingId,
                building: building,
                name: building['name_display']?.toString() ?? buildingId,
                id: buildingId,
                isRoom: false,
                score: buildingScore,
              ),
            ]
          : <CampusSearchResult>[];

      final rooms = building['rooms'];

      final roomResults = rooms is Map
          ? rooms.entries
                .map((roomEntry) {
                  final roomId = roomEntry.key.toString();
                  final room = Map<String, dynamic>.from(
                    roomEntry.value as Map,
                  );

                  final roomScore = _bestScore(
                    query: query,
                    queryTokens: queryTokens,
                    fields: _roomFields(roomId, room),
                  );

                  if (roomScore == 0) return null;

                  final score = math.max(
                    roomScore,
                    buildingScore > 0 ? (buildingScore * 0.35).round() : 0,
                  );

                  return CampusSearchResult(
                    buildingId: buildingId,
                    building: building,
                    name: room['name_display']?.toString() ?? roomId,
                    id: roomId,
                    isRoom: true,
                    room: room,
                    score: score,
                  );
                })
                .whereType<CampusSearchResult>()
                .toList()
          : <CampusSearchResult>[];

      return [...buildingResult, ...roomResults];
    }).toList()..sort((a, b) {
      final scoreComparison = b.score.compareTo(a.score);
      if (scoreComparison != 0) return scoreComparison;

      final hasNumber = RegExp(r'\d').hasMatch(query);

      if (hasNumber && a.isRoom != b.isRoom) {
        return a.isRoom ? -1 : 1;
      }

      return a.name.compareTo(b.name);
    });
  }
}

const Map<String, IconData> kPlaceIcons = {
  'room': MingCuteIcons.mgc_door_line,
  'house': MingCuteIcons.mgc_house_2_line,
  'building': MingCuteIcons.mgc_building_4_line,
  'classroom': MingCuteIcons.mgc_black_board_line,
  'lecture': MingCuteIcons.mgc_black_board_2_line,
  'hall': MingCuteIcons.mgc_seat_line,
  'lab': MingCuteIcons.mgc_flask_line,
  'study': MingCuteIcons.mgc_bulb_line,
  'cafe': MingCuteIcons.mgc_teacup_line,
  'food': MingCuteIcons.mgc_dinner_line,
  'grocery': MingCuteIcons.mgc_basket_line,
  'shop': MingCuteIcons.mgc_store_2_line,
  'book': MingCuteIcons.mgc_book_6_line,
  'bank': MingCuteIcons.mgc_bank_line,
  'clinic': MingCuteIcons.mgc_nurse_line,
  'admin': MingCuteIcons.mgc_briefcase_line,
  'student': MingCuteIcons.mgc_backpack_line,
  'restroom': MingCuteIcons.mgc_toilet_paper_line,
  'game': MingCuteIcons.mgc_game_2_line,
  'relax': MingCuteIcons.mgc_bed_line,
  'photo': MingCuteIcons.mgc_camera_line,
  'art': MingCuteIcons.mgc_brush_line,
  'exhibition': MingCuteIcons.mgc_award_line,
};

const List<(String, List<String>)> _iconRules = [
  ('lab', ['معمل', 'مختبر', 'لاب', 'lab', 'laboratory']),
  (
    'restroom',
    [
      'دورات المياه',
      'دورات مياه',
      'دورة مياه',
      'حمام',
      'حمامات',
      'toilet',
      'toilets',
      'restroom',
      'restrooms',
      'washroom',
      'bathroom',
    ],
  ),
  ('cafe', ['مقهى', 'كافيه', 'قهوة', 'شاي', 'cafe', 'coffee']),
  (
    'food',
    [
      'مطعم',
      'كافتيريا',
      'صالة الطعام',
      'قاعة الطعام',
      'restaurant',
      'cafeteria',
      'dining hall',
    ],
  ),
  ('grocery', ['بقالة', 'بقاله', 'ميني ماركت', 'grocery', 'minimarket']),
  (
    'books',
    ['متجر الكتب', 'بوكشوب', 'بوك شوب', 'bookshop', 'book shop', 'bookstore'],
  ),
  ('bank', ['بنك', 'bank', 'banking']),
  ('shop', ['فودافون', 'vodafone', 'متجر', 'shop', 'store']),
  (
    'game',
    [
      'تسلية',
      'ترفيه',
      'بولينج',
      'بلياردو',
      'بلايستيشن',
      'playstation',
      'bowling',
      'billiards',
      'gaming',
      'games',
    ],
  ),
  ('photo', ['جماعة التصوير', 'photography', 'photo club']),
  ('art', ['جماعة الفنون', 'الفنون التشكيلية', 'فنون تشكيلية', 'fine arts']),
  (
    'study',
    ['مساحات المذاكرة', 'مساحات مذاكرة', 'مذاكرة', 'study area', 'study space'],
  ),
  ('relax', ['استرخاء', 'relaxation', 'lounge']),
  ('clinic', ['عيادة', 'clinic', 'medical']),
  ('admin', ['عمادة', 'deanship']),
  (
    'student',
    [
      'دعم الطلبة',
      'دعم الطلبه',
      'دعم الطلاب',
      'خدمات الطلبة',
      'student support',
      'student services',
    ],
  ),
  ('exhibition', ['معارض', 'معرض', 'exhibition']),
  (
    'hall',
    [
      'قاعة المؤتمرات',
      'مؤتمرات',
      'مؤتمر',
      'دراما',
      'مسرح',
      'conference',
      'drama',
      'theatre',
      'theater',
    ],
  ),
  ('lecture', ['محاضرات', 'مدرج', 'lecture', 'auditorium']),
  (
    'classroom',
    [
      'قاعة دراسية',
      'قاعات التدريس',
      'الصفوف الدراسية',
      'classroom',
      'classrooms',
    ],
  ),
];

RegExp _ruleRegExp(List<String> words) {
  final alternatives = words
      .map((w) => RegExp.escape(normalizeSearchText(w)))
      .join('|');
  return RegExp('(?:^| )(?:ال)?(?:$alternatives)(?: |\$)');
}

final List<(String, RegExp)> _compiledIconRules = [
  for (final (key, words) in _iconRules) (key, _ruleRegExp(words)),
];

final Map<String, IconData> _placeIconCache = {};

IconData resolvePlaceIcon({
  required String cacheKey,
  required bool isRoom,
  required String name,
  List<String> keywords = const [],
  String? explicitKey,
}) {
  final pinned = explicitKey == null ? null : kPlaceIcons[explicitKey];
  if (pinned != null) return pinned;

  return _placeIconCache.putIfAbsent(cacheKey, () {
    final nameText = normalizeSearchText(name);
    for (final (key, pattern) in _compiledIconRules) {
      if (pattern.hasMatch(nameText)) return kPlaceIcons[key]!;
    }

    final keywordText = normalizeSearchText(keywords.join(' '));
    for (final (key, pattern) in _compiledIconRules) {
      if (pattern.hasMatch(keywordText)) return kPlaceIcons[key]!;
    }

    return kPlaceIcons[isRoom ? 'room' : 'house']!;
  });
}

IconData iconOfItem(Map<String, dynamic> item) =>
    (item['icon'] as IconData?) ??
    kPlaceIcons[item['type'] == 'room' ? 'room' : 'house']!;
