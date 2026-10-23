import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:ming_cute_icons/ming_cute_icons.dart';
import 'package:smooth_border/smooth_border.dart';
import 'package:solar_icons/solar_icons.dart';

void main() {
  runApp(const DarbApp());
}

class DarbApp extends StatelessWidget {
  const DarbApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'درب',
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

class _DarbMapPageState extends State<DarbMapPage> {
  static const LatLng _initialCenter = LatLng(23.5913, 58.1722);
  bool _isDaroobStaring = false;
  Timer? _animationTimer;
  final math.Random _random = math.Random();

  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  Marker? _currentMarker;

  StreamSubscription<Position>? _positionSubscription;

  LatLng? _currentPosition;

  bool _mapReady = false;
  bool _hasCentered = false;

  late Map<String, dynamic> campusPlaces;

  @override
  void initState() {
    super.initState();
    _startLocationTracking();
    loadCampusData().then((d) {
      campusPlaces = d;
    });
    _searchFocusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (_searchFocusNode.hasFocus) {
      _startStaring();
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
        _showMessage('يرجى تفعيل خدمة الموقع في هاتفك.');
        return;
      }

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
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
      _mapController.move(location, 18);
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

    _mapController.move(position, 18);
  }

  List<Map<String, dynamic>> searchResults = [];

  void searchCampus(String query) {
    final results = CampusSearch(campusPlaces)
        .search(query)
        .map(
          (result) => <String, dynamic>{
            'id': result.id,
            'name': result.name,
            'type': result.isRoom ? 'room' : 'building',
            'building_id': result.buildingId,
            if (result.isRoom) ...{
              'floor': result.room?['floor'],
              'buildingName':
                  result.building['name_display']?.toString() ??
                  result.buildingId,
            },
            'building': result.building,
          },
        )
        .toList();

    setState(() {
      searchResults = results;
    });
  }

  List<Marker> createMapMarkersForBuildings() {
    final List<Marker> markers = [];
    final Map<String, Color> markerColors = {
      "college": Color(0xFFC9826B),
      "teaching": Color(0xFFD6B58C),
      "library": Color(0xFF8F9B83),
      "research_center": Color(0xFFB7A5C7),
      "other": Color(0xFF7F9C9A),
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

            child: Icon(Icons.school, size: 20, color: Colors.white),
          ),
        ),
      );
    });

    return markers;
  }

  Marker createMapMarkerForBuilding(String id) {
    final Map<String, Color> markerColors = {
      "college": Color(0xFFC9826B),
      "teaching": Color(0xFFD6B58C),
      "library": Color(0xFF8F9B83),
      "research_center": Color(0xFFB7A5C7),
      "other": Color(0xFF7F9C9A),
    };

    final building = campusPlaces[id];

    return Marker(
      point: LatLng(building['lat'], building['lon']),
      width: 40.0,
      height: 40.0,
      rotate: true,
      child: CircleAvatar(
        backgroundColor: markerColors[building['genre'] as String],
        radius: 30,

        child: Icon(Icons.school, size: 20, color: Colors.white),
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
    _mapController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _animationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                onMapReady: _onMapReady,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.squ_navigator',
                  maxNativeZoom: 19,
                ),
                CurrentLocationLayer(
                  style: LocationMarkerStyle(
                    marker: StreamBuilder<Position>(
                      stream: Geolocator.getPositionStream(),
                      builder: (context, snapshot) {
                        final position = snapshot.data;
                        final marker = _currentMarker;

                        if (position == null || marker == null) {
                          return Image.asset(
                            'assets/images/daroob_sideways.png',
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.none,
                          );
                        }

                        final bearing = Geolocator.bearingBetween(
                          position.latitude,
                          position.longitude,
                          marker.point.latitude,
                          marker.point.longitude,
                        );

                        final sprite = _isDaroobStaring
                            ? _getStaringSprite(bearing)
                            : (asset: 'assets/images/daroob.png', flipX: false);

                        return Transform.flip(
                          flipX: sprite.flipX,

                          child: Transform.rotate(
                          angle: -math.pi/4,
                          
                          child: Image.asset(
                            sprite.asset,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.none,
                          ),
                        ));
                      },
                    ),
                    markerSize: const Size(40, 33.85),
                    markerDirection: MarkerDirection.heading,
                    showAccuracyCircle: true,
                  ),
                ),

                const RichAttributionWidget(
                  attributions: [TextSourceAttribution('مساهمو OpenStreetMap')],
                ),

                MarkerLayer(
                  markers: _currentMarker != null ? [_currentMarker!] : [],
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
                                      onTapOutside: (_) {
                                        _searchFocusNode.unfocus();
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
                                    duration: const Duration(milliseconds: 250),
                                    reverseDuration: const Duration(
                                      milliseconds: 180,
                                    ),
                                    switchInCurve:
                                        Curves.fastEaseInToSlowEaseOut,
                                    switchOutCurve: Curves.elasticOut,
                                    child: _searchController.text.isNotEmpty
                                        ? IconButton(
                                            key: const ValueKey('clear_button'),
                                            onPressed: () {
                                              setState(() {
                                                _searchController.clear();
                                              });
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
                              bottom: _isDaroobStaring ? 0 : -30,
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
                                              filterQuality: FilterQuality.none,
                                            )
                                            .animate(
                                              onPlay: (controller) => controller
                                                  .repeat(reverse: true),
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
                                _searchController.text.isNotEmpty &&
                                    MediaQuery.of(context).viewInsets.bottom > 0
                                ? ListView.builder(
                                    shrinkWrap: true,
                                    itemCount: searchResults.length,
                                    itemBuilder: (context, index) {
                                      final item = searchResults[index];
                                      final isRoom = item['type'] == 'room';
                                      if (isRoom && item['floor'] == '0') {
                                        item['floor'] = 'الأرضي';
                                      }
                                      return ListTile(
                                        leading: Icon(
                                          isRoom
                                              ? MingCuteIcons.mgc_door_line
                                              : MingCuteIcons.mgc_house_2_line,
                                        ),
                                        title: Text(item['name']),
                                        subtitle: Text(
                                          isRoom
                                              ? '${item['buildingName']} • الطابق ${item['floor']}'
                                              : 'مبنى',
                                        ),
                                        onTap: () {
                                          final building = item['building'];
                                          final lat = building['lat'];
                                          final lon = building['lon'];
                                          _mapController.move(
                                            LatLng(lat, lon),
                                            18,
                                          );
                                          _searchController.text = item['name'];
                                          _searchFocusNode.unfocus();
                                          _currentMarker =
                                              createMapMarkerForBuilding(
                                                item['building_id'],
                                              );
                                        },
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
        padding: EdgeInsets.only(bottom: 30),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _currentMarker != null
                ? FloatingActionButton(
                    heroTag: 'removeMarker',
                    elevation: 5,
                    tooltip: 'احذف العلامة',
                    onPressed: () {
                      setState(() {
                        _currentMarker = null;
                      });
                    },
                    child: const Icon(SolarIconsBold.mapPointRemove),
                  )
                : SizedBox.shrink(),

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
    );
  }
}

Future<Map<String, dynamic>> loadCampusData() async {
  final jsonString = await rootBundle.loadString('assets/data/campus.json');

  final Map<String, dynamic> data = jsonDecode(jsonString);

  return data;
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

({String asset, bool flipX}) _getStaringSprite(double bearing) {
  final direction = ((bearing % 360) + 360) % 360;

  if (direction >= 337.5 || direction < 22.5) {
    return (asset: 'assets/images/daroob_up.png', flipX: false);
  }

  if (direction < 67.5) {
    return (asset: 'assets/images/daroob_up_sideways.png', flipX: false);
  }

  if (direction < 112.5) {
    return (asset: 'assets/images/daroob_sideways.png', flipX: false);
  }

  if (direction < 157.5) {
    return (asset: 'assets/images/daroob_down_sideways.png', flipX: false);
  }

  if (direction < 202.5) {
    return (asset: 'assets/images/daroob_sideways.png', flipX: false);
  }

  if (direction < 247.5) {
    return (asset: 'assets/images/daroob_down_sideways.png', flipX: true);
  }

  if (direction < 292.5) {
    return (asset: 'assets/images/daroob_sideways.png', flipX: true);
  }

  return (asset: 'assets/images/daroob_up_sideways.png', flipX: true);
}
