import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../models/destination.dart';
import '../../models/poi.dart';
import '../walk_controller.dart';

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
    super.dispose();
  }

  void _onControllerUpdate() {
    setState(() {});
    // If walking has started and we have a position, center the map
    final pos = widget.controller.currentPosition;
    if (pos != null && widget.controller.status == WalkStatus.walking) {
      _mapController.move(
          LatLng(pos.latitude, pos.longitude), _mapController.camera.zoom);
    }
  }

  Future<void> _onStartWalk() async {
    try {
      await widget.controller.startWalk();
      if (widget.controller.status == WalkStatus.walking && mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => WalkScreen(controller: widget.controller),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start: ${widget.controller.statusMessage}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error starting walk: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dest = widget.destination;
    final center = LatLng(dest.centerLatitude, dest.centerLongitude);

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
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.notmiss.app',
              ),
              // POI markers
              MarkerLayer(
                markers: dest.pois.map((poi) => _buildPoiMarker(poi)).toList(),
              ),
              // User location dot
              if (widget.controller.currentPosition != null)
                MarkerLayer(
                  markers: [_buildUserMarker()],
                ),
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
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
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
                      '${dest.pois.length} points of interest',
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

          // ── Status message (error/permission) ────────────────────────────
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

          // ── Zoom Controls ────────────────────────────────────────────────
          Positioned(
            right: 16,
            bottom: 110,
            child: Column(
              children: [
                FloatingActionButton(
                  heroTag: 'homeZoomIn',
                  mini: true,
                  backgroundColor: Colors.white,
                  onPressed: () {
                    _mapController.move(
                        _mapController.camera.center, _mapController.camera.zoom + 1);
                  },
                  child: const Icon(Icons.add, color: Colors.black87),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'homeZoomOut',
                  mini: true,
                  backgroundColor: Colors.white,
                  onPressed: () {
                    _mapController.move(
                        _mapController.camera.center, _mapController.camera.zoom - 1);
                  },
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
                backgroundColor: const Color(0xFF1B5E20),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 4,
              ),
              child: const Text(
                'START WALK',
                style: TextStyle(
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
            color: const Color(0xFF2E7D32),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 4,
              ),
            ],
          ),
          child: const Icon(Icons.place, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  Marker _buildUserMarker() {
    final pos = widget.controller.currentPosition!;
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
              color: Colors.blue.withOpacity(0.4),
              blurRadius: 8,
              spreadRadius: 2,
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline walk HUD, pushed on top of HomeScreen when walk starts.
class WalkScreen extends StatefulWidget {
  final WalkController controller;

  const WalkScreen({super.key, required this.controller});

  @override
  State<WalkScreen> createState() => _WalkScreenState();
}

class _WalkScreenState extends State<WalkScreen> {
  final MapController _mapController = MapController();
  LatLng? _lastPos;

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
    setState(() {});
    // Auto-follow user on the map without snapping zoom
    final pos = widget.controller.currentPosition;
    if (pos != null) {
      final newLatLng = LatLng(pos.latitude, pos.longitude);
      if (_lastPos == null || _lastPos!.latitude != newLatLng.latitude || _lastPos!.longitude != newLatLng.longitude) {
        _lastPos = newLatLng;
        _mapController.move(newLatLng, _mapController.camera.zoom);
      }
    }
  }

  void _onStop() {
    widget.controller.stopWalk();
    Navigator.of(context).pop();
  }

  void _zoomIn() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, currentZoom + 1);
  }

  void _zoomOut() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, currentZoom - 1);
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
              initialCenter: _lastPos ?? LatLng(dest.centerLatitude, dest.centerLongitude),
              initialZoom: 16.5,
              minZoom: 12,
              maxZoom: 19,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.notmiss.app',
              ),
              MarkerLayer(
                markers: dest.pois.map((poi) {
                  final triggered = ctrl.triggeredPoiIds.contains(poi.id);
                  return Marker(
                    point: LatLng(poi.latitude, poi.longitude),
                    width: 36,
                    height: 36,
                    child: Container(
                      decoration: BoxDecoration(
                        color: triggered
                            ? Colors.grey[400]
                            : const Color(0xFF2E7D32),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: Icon(
                        triggered ? Icons.check : Icons.place,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  );
                }).toList(),
              ),
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
                              color: Colors.blue.withOpacity(0.4),
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

          // ── Zoom Controls ────────────────────────────────────────────────
          Positioned(
            right: 16,
            bottom: 230,
            child: Column(
              children: [
                FloatingActionButton(
                  heroTag: 'walkZoomIn',
                  mini: true,
                  backgroundColor: Colors.white,
                  onPressed: _zoomIn,
                  child: const Icon(Icons.add, color: Colors.black87),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'walkZoomOut',
                  mini: true,
                  backgroundColor: Colors.white,
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
                  color: Colors.white.withOpacity(0.97),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
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
                            ctrl.statusMessage ?? 'Walking…',
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
                        '📍 ${ctrl.activePoi!.name}',
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

                    const SizedBox(height: 16),

                    // GPS info
                    if (pos != null)
                      Text(
                        '🛰 ${pos.latitude.toStringAsFixed(5)}, '
                        '${pos.longitude.toStringAsFixed(5)}  '
                        '± ${pos.accuracy.toStringAsFixed(0)} m',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[500],
                          fontFamily: 'monospace',
                        ),
                      ),

                    const SizedBox(height: 16),

                    // Visited counter
                    Text(
                      '${ctrl.triggeredPoiIds.length} / ${dest.pois.length} places visited',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Stop Walk button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _onStop,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red[700],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          'STOP WALK',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
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
