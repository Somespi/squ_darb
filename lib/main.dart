import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
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
        fontFamily: 'Roboto',
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
  static const LatLng _squLocation = LatLng(23.5880, 58.1660);

  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  StreamSubscription<Position>? _positionSubscription;

  LatLng? _currentPosition;

  bool _mapReady = false;
  bool _hasCentered = false;

  @override
  void initState() {
    super.initState();
    _startLocationTracking();
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

  void _goToUniversity() {
    _mapController.move(_squLocation, 17);
    _showMessage('جامعة السلطان قابوس');
  }

  void _searchPlace(String query) {
    final text = query.trim();

    if (text.isEmpty) {
      _showMessage('اكتب اسم المكان الذي تريد البحث عنه.');
      return;
    }

    // البحث هنا تجريبي للأماكن المحددة فقط.
    // يمكن ربطه لاحقاً بخدمة بحث جغرافي حقيقية.
    final normalized = text.toLowerCase();

    if (normalized.contains('جامعة') ||
        normalized.contains('سلطان قابوس') ||
        normalized.contains('squ') ||
        normalized.contains('sultan qaboos')) {
      _goToUniversity();
      return;
    }

    if (normalized.contains('موقعي') ||
        normalized.contains('موقعي الحالي') ||
        normalized.contains('my location')) {
      _goToCurrentLocation();
      return;
    }

    _showMessage(
      'لم يتم العثور على المكان. جرّب البحث عن جامعة السلطان قابوس.',
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
                  style: const LocationMarkerStyle(
                    marker: DefaultLocationMarker(
                      child: Icon(
                        Icons.navigation,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    markerSize: Size(40, 40),
                    markerDirection: MarkerDirection.heading,
                    showAccuracyCircle: true,
                  ),
                ),

                const RichAttributionWidget(
                  attributions: [TextSourceAttribution('مساهمو OpenStreetMap')],
                ),
              ],
            ),

            // لوحة البحث والأماكن المحفوظة.
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  constraints: const BoxConstraints(maxHeight: 340),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 12,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                  
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          16,
                          4,
                          12,
                          4,
                        ),
                        child: Row(
                          
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                onChanged: (String _) {
                                  setState(() {});
                                },
                                textInputAction: TextInputAction.search,
                                textDirection: TextDirection.rtl,
                                onSubmitted: _searchPlace,
                                decoration: const InputDecoration(
                                  hintText: 'ابحث في الخريطة...',
                                  hintTextDirection: TextDirection.rtl,
                                  border: InputBorder.none,
                                  prefixIcon: Icon(SolarIconsBold.map),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'بحث',
                              onPressed: () =>
                                  _searchPlace(_searchController.text),
                              icon: const Icon(
                                Icons.search,
                                size: 28,
                                color: Color(0xFF5F6368),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const Divider(height: 1),

                      // قائمة الأماكن.
                      Flexible(
                        child: AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                          alignment: Alignment.topCenter,
                          child: _searchController.text.isNotEmpty
                              ? ListView(
                                  shrinkWrap: true,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  children: [
                                    ListTile(
                                      leading: const CircleAvatar(
                                        child: Icon(Icons.school_outlined),
                                      ),
                                      title: const Text('جامعة السلطان قابوس'),
                                      subtitle: const Text('مكان مقترح'),
                                      onTap: _goToUniversity,
                                    ),
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // زر موقعي الحالي أسفل اليسار.
            // Positioned(
            //   left: 16,
            //   bottom: 32,
            //   child:

            // ),
          ],
        ),
      ),

      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: 30),
        child: FloatingActionButton(
          heroTag: 'currentLocationButton',
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF2877D4),
          elevation: 5,
          tooltip: 'موقعي الحالي',
          onPressed: _goToCurrentLocation,
          child: const Icon(Icons.my_location_rounded),
        ),
      ),
    );
  }
}
