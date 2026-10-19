import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:smooth_border/smooth_border.dart';
import 'package:solar_icons/solar_icons.dart';
import 'package:text_form_field_flutter/text_form_field_flutter.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wifi_scan/wifi_scan.dart';


void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SQUDarbApp());
}

class SQUDarbApp extends StatelessWidget {
  const SQUDarbApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SQU Darb',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176B55)),
        useMaterial3: true,
      ),
      home: const CampusMapPage(),
    );
  }
}

class CampusMapPage extends StatefulWidget {
  const CampusMapPage({super.key});

  @override
  State<CampusMapPage> createState() => _CampusMapPageState();
}

class _CampusMapPageState extends State<CampusMapPage> {
  final MapController _mapController = MapController();

  static const LatLng _campusCenter = LatLng(23.5913, 58.1722);

  bool _isSelectionMode = false;
  bool _isRecording = false;
  String _selectedCategory = 'others';
  Offset _boxTopLeft = const Offset(100, 200);
  Offset _boxBottomRight = const Offset(300, 500);
  double _currentMagMagnitude = 0.0;
  final List<Map<String, dynamic>> _loggedGridCells = [];
  StreamSubscription? _magSubscription;
  StreamSubscription? _userStepSubscription;

  @override
  void initState() {
    super.initState();
    _initSensors();
  }

  void _initSensors() {
    _magSubscription = magnetometerEventStream(samplingPeriod: SensorInterval.fastestInterval).listen(
      (MagnetometerEvent event) {
        if (mounted) {
          setState(() {
            _currentMagMagnitude = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
          });
        }
      },
      onError: (error) {
        debugPrint("Magnetometer error: $error");
      },
    );

    // Continuous motion tracking loop tied to step triggers
    _userStepSubscription = userAccelerometerEventStream(samplingPeriod: SensorInterval.normalInterval).listen((UserAccelerometerEvent event) {
      if (_isRecording) {
        // High-pass threshold simulating a step event trigger pattern
        double accelerationNorm = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
        if (accelerationNorm > 12.0) {
          _autoLogCurrentGridCell();
        }
      }
    });
  }

  // Mimicked programmatic Wi-Fi environment capture (Leverages native Android bridge capability)
  Map<String, int> _mockAndroidWifiScan() {
    return {
      "00:14:22:01:23:45": -62 - math.Random().nextInt(15),
      "00:14:22:01:23:46": -70 - math.Random().nextInt(10),
      "00:15:99:A3:BC:11": -55 - math.Random().nextInt(20),
    };
  }

  void _autoLogCurrentGridCell() {
    int simulatedGridX = ((_boxTopLeft.dx + _boxBottomRight.dx) / 2 / 0.5).floor() % 100;
    int simulatedGridY = ((_boxTopLeft.dy + _boxBottomRight.dy) / 2 / 0.5).floor() % 100;

    Map<String, dynamic> cellData = {
      "grid_x": simulatedGridX,
      "grid_y": simulatedGridY,
      "label": _selectedCategory,
      "magnetic_magnitude": double.parse(_currentMagMagnitude.toStringAsFixed(2)),
      "wifi_snapshot": _mockAndroidWifiScan()
    };

    _loggedGridCells.add(cellData);
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Logged node at grid ($simulatedGridX, $simulatedGridY) under '$_selectedCategory'"),
        duration: const Duration(milliseconds: 500),
      ),
    );
  }

  void _showSaveExportDialog() {
    final nameController = TextEditingController();
    final floorController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Export Dataset"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: "Place/Building Name"),
            ),
            TextField(
              controller: floorController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Floor Level"),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () async {
              String placeName = nameController.text.trim();
              String floorLevel = floorController.text.trim();
              Navigator.pop(context);
              if (placeName.isNotEmpty && floorLevel.isNotEmpty) {
                await _compileAndShareData(placeName, int.parse(floorLevel));
              }
            },
            child: const Text("Share Payload"),
          ),
        ],
      ),
    );
  }

  Future<void> _compileAndShareData(String placeName, int floor) async {
    Map<String, dynamic> exportPayload = {
      "metadata": {
        "place_name": placeName,
        "floor_level": floor,
        "grid_scale_meters": 0.5,
        "timestamp": DateTime.now().toIso8601String()
      },
      "sensor_fingerprints": _loggedGridCells
    };

    String jsonOutput = const JsonEncoder.withIndent('  ').convert(exportPayload);
    
    // Invoke native Share sheet pipeline
    await SharePlus.instance.share(ShareParams(text:jsonOutput, subject: 'Fingerprint Map - $placeName (Floor $floor)'));
    
    setState(() {
      _loggedGridCells.clear();
      _isRecording = false;
      _isSelectionMode = false;
    });
  }

  @override
  void dispose() {
    _magSubscription?.cancel();
    _userStepSubscription?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          _buildMapLayer(),
          if (_isSelectionMode) _buildSelectionOverlay(),
          _buildTopConfigurationPanel(),
        ],
      ),
      floatingActionButton: _buildContextualActionControls(),
    );
  }

  Widget _buildMapLayer() {
    return FlutterMap(
      mapController: _mapController,
      options: const MapOptions(
        initialCenter: _campusCenter,
        initialZoom: 18,
        minZoom: 15,
        maxZoom: 20,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.squ_navigator',
        ),
        CurrentLocationLayer(),
      ],
    );
  }

  Widget _buildSelectionOverlay() {
    return Positioned.fromRect(
      rect: Rect.fromPoints(_boxTopLeft, _boxBottomRight),
      child: GestureDetector(
        onPanUpdate: (details) {
          if (!_isRecording) {
            setState(() {
              _boxBottomRight += details.delta;
            });
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: _isRecording ? Colors.red.withOpacity(0.2) : Colors.blue.withOpacity(0.25),
            border: Border.all(
              color: _isRecording ? Colors.red : Colors.blue,
              width: 3,
            ),
          ),
          child: CustomPaint(
            painter: GridGridLinesPainter(),
          ),
        ),
      ),
    );
  }

  Widget _buildTopConfigurationPanel() {
    return Positioned(
      top: 60,
      left: 16,
      right: 16,
      child: Card(
        color: Colors.white.withOpacity(0.95),
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildCategoryChip('class', Icons.class_),
              _buildCategoryChip('lab', Icons.science),
              _buildCategoryChip('stairs', Icons.stairs),
              _buildCategoryChip('others', Icons.more_horiz),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryChip(String label, IconData icon) {
    bool isSelected = _selectedCategory == label;
    return ChoiceChip(
      avatar: Icon(icon, size: 16, color: isSelected ? Colors.white : Colors.black54),
      label: Text(label),
      selected: isSelected,
      onSelected: _isRecording ? null : (selected) {
        if (selected) {
          setState(() {
            _selectedCategory = label;
          });
        }
      },
    );
  }

  Widget _buildContextualActionControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              FloatingActionButton.extended(
                heroTag: 'select_btn',
onPressed: _isRecording ? null : () {
setState(() {
_isSelectionMode = !_isSelectionMode;
});
},
backgroundColor: _isSelectionMode ? Colors.blue : Colors.grey[200],
label: Text(_isSelectionMode ? "Clear Frame" : "Select Area"),
icon: const Icon(Icons.crop_free),
),
const SizedBox(width: 10),
if (_isSelectionMode)
FloatingActionButton.extended(
heroTag: 'record_btn',
onPressed: () {
setState(() {
_isRecording = !_isRecording;
});
},
backgroundColor: _isRecording ? Colors.red : Colors.green,
label: Text(_isRecording ? "Stop Logging" : "Start Run"),
icon: Icon(_isRecording ? Icons.stop : Icons.play_arrow),
),
],
),
if (_loggedGridCells.isNotEmpty && !_isRecording)
FloatingActionButton.extended(
heroTag: 'export_btn',
onPressed: _showSaveExportDialog,
backgroundColor: const Color(0xFF176B55),
label: const Text("Save Map"),
icon: const Icon(Icons.ios_share),
),
],
),
);
}
}
// Custom Painter mapping out 0.5-meter cross-sections on screen space
class GridGridLinesPainter extends CustomPainter {
@override
void paint(Canvas canvas, Size size) {
var paint = Paint()
..color = Colors.white.withOpacity(0.4)
..strokeWidth = 1.0;
double horizontalDensity = 25.0; // Corresponds roughly to scale metrics
for (double i = 0; i < size.width; i += horizontalDensity) {
canvas.drawLine(Offset(i, 0), Offset(i, size.height), paint);
}
for (double i = 0; i < size.height; i += horizontalDensity) {
canvas.drawLine(Offset(0, i), Offset(size.width, i), paint);
}
}
@override
bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}