import 'dart:math' show pi;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
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
              // User location dot with compass
              if (pos != null)
                MarkerLayer(markers: [_buildUserMarker(pos)]),
            ],
          ),

          // ── Nearby POIs chip ─────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _NearbyPoiChip(
                        pos: pos,
                        pois: dest.pois,
                        radiusM: 100,
                        onPoiTap: (poi) {
                          _mapController.move(
                            LatLng(poi.latitude, poi.longitude),
                            18,
                          );
                        },
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'v0.1.0',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.black54,
                        ),
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
                // Reset North Button (shows only when rotated)
                StreamBuilder<MapEvent>(
                  stream: _mapController.mapEventStream,
                  builder: (context, _) {
                    final rotation = _mapController.camera.rotation;
                    if (rotation == 0.0) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: FloatingActionButton(
                        heroTag: 'homeResetNorth',
                        mini: true,
                        backgroundColor: Colors.white,
                        elevation: 3,
                        onPressed: () => _mapController.rotate(0),
                        child: Transform.rotate(
                          angle: -rotation * pi / 180,
                          child: const Icon(Icons.explore, color: Colors.red),
                        ),
                      ),
                    );
                  },
                ),
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
      width: 48,
      height: 48,
      rotate: true, // Align marker coordinate system with map (North is up)
      child: StreamBuilder<CompassEvent>(
        stream: FlutterCompass.events,
        builder: (context, snapshot) {
          final heading = snapshot.data?.heading;

          if (heading == null) {
            // Fallback if compass is unavailable or hasn't emitted yet
            return Center(
              child: Container(
                width: 24,
                height: 24,
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

          // We have a compass heading! Draw dot + direction arrow
          return Transform.rotate(
            angle: heading * pi / 180,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  top: 0,
                  child: Icon(
                    Icons.navigation, // Arrow pointing UP
                    color: Colors.blue.withValues(alpha: 0.8),
                    size: 28,
                  ),
                ),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.blue.withValues(alpha: 0.4),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
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
              // User blue dot with compass
              if (pos != null)
                MarkerLayer(markers: [_buildUserMarker(pos)]),
            ],
          ),

          // ── Zoom + Locate Controls ───────────────────────────────────────
          Positioned(
            right: 16,
            top: 60,
            child: Column(
              children: [
                // Reset North Button (shows only when rotated)
                StreamBuilder<MapEvent>(
                  stream: _mapController.mapEventStream,
                  builder: (context, _) {
                    final rotation = _mapController.camera.rotation;
                    if (rotation == 0.0) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: FloatingActionButton(
                        heroTag: 'walkResetNorth',
                        mini: true,
                        backgroundColor: Colors.white,
                        elevation: 3,
                        onPressed: () => _mapController.rotate(0),
                        child: Transform.rotate(
                          angle: -rotation * pi / 180,
                          child: const Icon(Icons.explore, color: Colors.red),
                        ),
                      ),
                    );
                  },
                ),
                // Locate User Button
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

                    // GPS signal quality indicator
                    if (pos != null) _GpsAccuracyBar(accuracy: pos.accuracy),

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

  Marker _buildUserMarker(dynamic pos) {
    return Marker(
      point: LatLng(pos.latitude, pos.longitude),
      width: 48,
      height: 48,
      rotate: true, // Align marker coordinate system with map (North is up)
      child: StreamBuilder<CompassEvent>(
        stream: FlutterCompass.events,
        builder: (context, snapshot) {
          final heading = snapshot.data?.heading;

          if (heading == null) {
            // Fallback if compass is unavailable or hasn't emitted yet
            return Center(
              child: Container(
                width: 24,
                height: 24,
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

          // We have a compass heading! Draw dot + direction arrow
          return Transform.rotate(
            angle: heading * pi / 180,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  top: 0,
                  child: Icon(
                    Icons.navigation, // Arrow pointing UP
                    color: Colors.blue.withValues(alpha: 0.8),
                    size: 28,
                  ),
                ),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.blue.withValues(alpha: 0.4),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
/// Chip displayed on the home screen showing how many POIs are within
/// [radiusM] metres of the user. Tapping opens a bottom sheet list.
class _NearbyPoiChip extends StatelessWidget {
  final dynamic pos; // Position? from geolocator
  final List<dynamic> pois; // List<Poi>
  final double radiusM;
  final void Function(dynamic poi) onPoiTap;

  const _NearbyPoiChip({
    required this.pos,
    required this.pois,
    required this.radiusM,
    required this.onPoiTap,
  });

  List<dynamic> _nearbyPois() {
    if (pos == null) return [];
    return pois.where((poi) {
      final dist = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        poi.latitude,
        poi.longitude,
      );
      return dist <= radiusM;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final nearby = _nearbyPois();
    final hasLocation = pos != null;
    final count = nearby.length;

    final Color chipColor;
    final Color textColor;
    if (!hasLocation) {
      chipColor = Colors.black.withValues(alpha: 0.55);
      textColor = Colors.white70;
    } else if (count == 0) {
      chipColor = Colors.black.withValues(alpha: 0.55);
      textColor = Colors.white;
    } else {
      chipColor = const Color(0xFF1B5E20).withValues(alpha: 0.92);
      textColor = Colors.white;
    }

    final label = !hasLocation
        ? 'Локацію не визначено'
        : count == 0
            ? 'Жодної точки поруч'
            : '$count ${_poiWord(count)} поряд';

    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onTap: count == 0
            ? null
            : () => _showNearbySheet(context, nearby),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: chipColor,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                count > 0 ? Icons.place : Icons.location_off,
                color: textColor,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 4),
                Icon(Icons.keyboard_arrow_down, color: textColor, size: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _poiWord(int n) {
    if (n == 1) return 'точка';
    if (n >= 2 && n <= 4) return 'точки';
    return 'точок';
  }

  void _showNearbySheet(BuildContext context, List<dynamic> nearby) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Поряд з вами (${radiusM.toInt()} м)',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Divider(height: 1),
              ...nearby.map((poi) {
                final dist = pos != null
                    ? Geolocator.distanceBetween(
                        pos.latitude,
                        pos.longitude,
                        poi.latitude,
                        poi.longitude,
                      ).round()
                    : 0;
                return ListTile(
                  leading: const Icon(Icons.place, color: Color(0xFF2E7D32)),
                  title: Text(poi.name),
                  trailing: Text(
                    '$dist м',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    onPoiTap(poi);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
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

// ─────────────────────────────────────────────────────────────────────────────
/// GPS signal quality bar — like a phone signal indicator.
/// Green bars = good accuracy, orange = ok, red = poor.
class _GpsAccuracyBar extends StatelessWidget {
  final double accuracy;
  const _GpsAccuracyBar({required this.accuracy});

  @override
  Widget build(BuildContext context) {
    // Determine colour and label based on accuracy
    final Color color;
    final String label;
    final int bars; // 1-4

    if (accuracy <= 8) {
      color = Colors.green[600]!;
      label = '±${accuracy.toStringAsFixed(0)} м — відмінно';
      bars = 4;
    } else if (accuracy <= 15) {
      color = Colors.green[400]!;
      label = '±${accuracy.toStringAsFixed(0)} м — добре';
      bars = 3;
    } else if (accuracy <= 25) {
      color = Colors.orange[600]!;
      label = '±${accuracy.toStringAsFixed(0)} м — задовільно';
      bars = 2;
    } else {
      color = Colors.red[400]!;
      label = '±${accuracy.toStringAsFixed(0)} м — слабкий сигнал';
      bars = 1;
    }

    return Row(
      children: [
        // Bar chart (4 bars, like signal strength)
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(4, (i) {
            final filled = i < bars;
            final barHeight = 6.0 + i * 3.0; // 6, 9, 12, 15
            return Container(
              width: 4,
              height: barHeight,
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                color: filled ? color : Colors.grey[300],
                borderRadius: BorderRadius.circular(1),
              ),
            );
          }),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: color),
        ),
      ],
    );
  }
}
