import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../models/destination.dart';
import '../../models/poi.dart';
import '../walk_controller.dart';

// ── Colour constants ──────────────────────────────────────────────────────────
const _kGreen = Color(0xFF1B5E20);
const _kGreenMarker = Color(0xFF2E7D32);

/// The home screen: map + Start Walk button.
///
/// Shows the destination map, all POI markers, and the user's current GPS dot.
class HomeScreen extends StatefulWidget {
  final Destination destination;
  final WalkController controller;

  const HomeScreen({
    super.key,
    required this.destination,
    required this.controller,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerUpdate);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdate);
    _mapController.dispose();
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _onStartWalk() async {
    try {
      await widget.controller.startWalk();
      if (!mounted) return;
      if (widget.controller.status == WalkStatus.walking) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => WalkScreen(controller: widget.controller),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                widget.controller.statusMessage ?? 'Could not start walk.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dest = widget.destination;
    final center = LatLng(dest.centerLatitude, dest.centerLongitude);
    final pos = widget.controller.currentPosition;

    return Scaffold(
      body: Stack(
        children: [
          // ── Map ─────────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: dest.defaultZoom,
              minZoom: 12,
              maxZoom: 19,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
                scrollWheelVelocity: 0.02,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.notmiss.app',
                // Cache tiles in memory to reduce re-fetches on pan
                tileProvider: NetworkTileProvider(),
              ),
              // POI markers
              MarkerLayer(
                markers: dest.pois.map(_buildPoiMarker).toList(),
              ),
              // User location dot
              if (pos != null)
                MarkerLayer(markers: [_buildUserMarker(pos)]),
            ],
          ),

          // ── Top title bar ────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dest.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${dest.pois.length} точок інтересу',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Status message (permission error) ─────────────────────────────
          if (widget.controller.statusMessage != null &&
              widget.controller.status == WalkStatus.idle)
            Positioned(
              bottom: 130,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  border: Border.all(color: Colors.red[200]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.controller.statusMessage!,
                  style: TextStyle(color: Colors.red[700]),
                ),
              ),
            ),

          // ── Zoom + Locate Controls ───────────────────────────────────────
          Positioned(
            right: 16,
            top: 100,
            child: Column(
              children: [
                // Locate me button
                FloatingActionButton(
                  heroTag: 'homeLocateMe',
                  mini: true,
                  backgroundColor: Colors.white,
                  elevation: 3,
                  onPressed: () {
                    if (pos != null) {
                      _mapController.move(
                          LatLng(pos.latitude, pos.longitude), 17);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Локація ще невідома. Натисни Start Walk спочатку.'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  child: Icon(
                    pos != null
                        ? Icons.my_location
                        : Icons.location_searching,
                    color: pos != null ? Colors.blue : Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'homeZoomIn',
                  mini: true,
                  backgroundColor: Colors.white,
                  elevation: 3,
                  onPressed: () => _mapController.move(
                      _mapController.camera.center,
                      _mapController.camera.zoom + 1),
                  child: const Icon(Icons.add, color: Colors.black87),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'homeZoomOut',
                  mini: true,
                  backgroundColor: Colors.white,
                  elevation: 3,
                  onPressed: () => _mapController.move(
                      _mapController.camera.center,
                      _mapController.camera.zoom - 1),
                  child: const Icon(Icons.remove, color: Colors.black87),
                ),
              ],
            ),
          ),

          // ── Start Walk button ────────────────────────────────────────────
          Positioned(
            bottom: 40,
            left: 32,
            right: 32,
            child: ElevatedButton(
              onPressed: widget.controller.status != WalkStatus.walking
                  ? _onStartWalk
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 4,
              ),
              child: Text(
                widget.controller.status == WalkStatus.stopped
                    ? 'РОЗПОЧАТИ ЗНОВУ'
                    : 'ПОЧАТИ ПРОГУЛЯНКУ',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Marker _buildPoiMarker(Poi poi) {
    return Marker(
      point: LatLng(poi.latitude, poi.longitude),
      width: 36,
      height: 36,
      child: Tooltip(
        message: poi.name,
        child: Container(
          decoration: BoxDecoration(
            color: _kGreenMarker,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 4,
              ),
            ],
          ),
          child: const Icon(Icons.place, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  Marker _buildUserMarker(dynamic pos) {
    return Marker(
      point: LatLng(pos.latitude, pos.longitude),
      width: 24,
      height: 24,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.blue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: Colors.blue.withValues(alpha: 0.4),
              blurRadius: 8,
              spreadRadius: 2,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
/// Inline walk HUD, pushed on top of HomeScreen when walk starts.
// ─────────────────────────────────────────────────────────────────────────────
class WalkScreen extends StatefulWidget {
  final WalkController controller;

  const WalkScreen({super.key, required this.controller});

  @override
  State<WalkScreen> createState() => _WalkScreenState();
}

class _WalkScreenState extends State<WalkScreen> {
  final MapController _mapController = MapController();
  LatLng? _lastPos;
  bool _followUser = true; // auto-follow; turns off if user pans manually

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
    final pos = widget.controller.currentPosition;
    if (pos != null) {
      _lastPos = LatLng(pos.latitude, pos.longitude);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_update);
    _mapController.dispose();
    super.dispose();
  }

  void _update() {
    if (!mounted) return;
    final pos = widget.controller.currentPosition;
    if (pos != null && _followUser) {
      final newLatLng = LatLng(pos.latitude, pos.longitude);
      if (_lastPos == null ||
          _lastPos!.latitude != newLatLng.latitude ||
          _lastPos!.longitude != newLatLng.longitude) {
        _lastPos = newLatLng;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _followUser) {
            _mapController.move(newLatLng, _mapController.camera.zoom);
          }
        });
      }
    }
    setState(() {});
  }

  void _onStop() {
    widget.controller.stopWalk();
    Navigator.of(context).pop();
  }

  void _zoomIn() => _mapController.move(
      _mapController.camera.center, _mapController.camera.zoom + 1);

  void _zoomOut() => _mapController.move(
      _mapController.camera.center, _mapController.camera.zoom - 1);

  void _locateMe() {
    final pos = widget.controller.currentPosition;
    if (pos != null) {
      _followUser = true;
      _mapController.move(LatLng(pos.latitude, pos.longitude), 17);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final dest = ctrl.destination;
    final pos = ctrl.currentPosition;

    return Scaffold(
      body: Stack(
        children: [
          // ── Map ─────────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter:
                  _lastPos ?? LatLng(dest.centerLatitude, dest.centerLongitude),
              initialZoom: 17,
              minZoom: 12,
              maxZoom: 19,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
                scrollWheelVelocity: 0.02,
              ),
              onPositionChanged: (_, hasGesture) {
                if (hasGesture) _followUser = false;
              },
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.notmiss.app',
                tileProvider: NetworkTileProvider(),
              ),
              // POI markers — visited ones turn grey with a checkmark
              MarkerLayer(
                markers: dest.pois.map((poi) {
                  final triggered = ctrl.triggeredPoiIds.contains(poi.id);
                  final isActive = ctrl.activePoi?.id == poi.id;
                  return Marker(
                    point: LatLng(poi.latitude, poi.longitude),
                    width: isActive ? 42 : 36,
                    height: isActive ? 42 : 36,
                    child: Tooltip(
                      message: poi.name,
                      child: Container(
                        decoration: BoxDecoration(
                          color: triggered
                              ? Colors.grey[400]
                              : isActive
                                  ? Colors.orange[700]
                                  : _kGreenMarker,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white,
                            width: isActive ? 3 : 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: Icon(
                          triggered ? Icons.check : Icons.place,
                          color: Colors.white,
                          size: isActive ? 22 : 18,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              // User blue dot
              if (pos != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(pos.latitude, pos.longitude),
                      width: 24,
                      height: 24,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.blue.withValues(alpha: 0.4),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // ── Zoom + Locate Controls ───────────────────────────────────────
          Positioned(
            right: 16,
            top: 60,
            child: Column(
              children: [
                FloatingActionButton(
                  heroTag: 'walkLocateMe',
                  mini: true,
                  backgroundColor: Colors.white,
                  elevation: 3,
                  onPressed: _locateMe,
                  child: Icon(
                    pos != null && _followUser
                        ? Icons.my_location
                        : Icons.location_searching,
                    color: _followUser ? Colors.blue : Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'walkZoomIn',
                  mini: true,
                  backgroundColor: Colors.white,
                  elevation: 3,
                  onPressed: _zoomIn,
                  child: const Icon(Icons.add, color: Colors.black87),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'walkZoomOut',
                  mini: true,
                  backgroundColor: Colors.white,
                  elevation: 3,
                  onPressed: _zoomOut,
                  child: const Icon(Icons.remove, color: Colors.black87),
                ),
              ],
            ),
          ),

          // ── Walk HUD bottom panel ────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.97),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 12,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Status row
                    Row(
                      children: [
                        _StatusDot(status: ctrl.status),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            ctrl.statusMessage ?? 'Прогулянка…',
                            style: const TextStyle(fontSize: 14),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),

                    if (ctrl.activePoi != null) ...[
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      Text(
                        ctrl.activePoi!.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        ctrl.activePoi!.shortDescription,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],

                    const SizedBox(height: 12),

                    // GPS accuracy info
                    if (pos != null)
                      Row(
                        children: [
                          Icon(Icons.gps_fixed,
                              size: 12, color: Colors.grey[400]),
                          const SizedBox(width: 4),
                          Text(
                            '${pos.latitude.toStringAsFixed(5)}, '
                            '${pos.longitude.toStringAsFixed(5)}'
                            '  ±${pos.accuracy.toStringAsFixed(0)} м',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[500],
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),

                    const SizedBox(height: 8),

                    // Visited counter + stop button row
                    Row(
                      children: [
                        Text(
                          '${ctrl.triggeredPoiIds.length} / ${dest.pois.length} місць відвідано',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        const Spacer(),
                        ElevatedButton(
                          onPressed: _onStop,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red[700],
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            elevation: 2,
                          ),
                          child: const Text(
                            'ЗУПИНИТИ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _StatusDot extends StatelessWidget {
  final WalkStatus status;
  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status) {
      case WalkStatus.walking:
        color = Colors.green;
      case WalkStatus.stopped:
        color = Colors.red;
      case WalkStatus.idle:
        color = Colors.grey;
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
