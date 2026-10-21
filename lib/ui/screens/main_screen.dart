import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:latlong2/latlong.dart';
import '../../models/poi.dart';
import '../../models/enriched_poi.dart';
import '../walk_controller.dart';
import 'package:geolocator/geolocator.dart'; // For Position

const _kGreen = Color(0xFF2E7D32);

/// Main unified screen that immediately starts the walk and shows the HUD.
class MainScreen extends StatefulWidget {
  final WalkController controller;

  const MainScreen({super.key, required this.controller});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final MapController _mapController = MapController();
  LatLng? _lastPos;
  bool _followUser = true; // auto-follow; turns off if user pans manually

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
    // Start walk automatically on first load only (not after user stopped)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.controller.status == WalkStatus.idle) {
        widget.controller.startWalk();
      }
    });
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
          Geolocator.distanceBetween(
                _lastPos!.latitude,
                _lastPos!.longitude,
                newLatLng.latitude,
                newLatLng.longitude,
              ) >
              2) {
        _lastPos = newLatLng;
        double zoom = widget.controller.destination.defaultZoom;
        try {
          zoom = _mapController.camera.zoom;
        } catch (_) {}
        _mapController.move(newLatLng, zoom);
      }
    }
    setState(() {});
  }

  void _locateMe() {
    final pos = widget.controller.currentPosition;
    if (pos != null) {
      _followUser = true;
      _mapController.move(LatLng(pos.latitude, pos.longitude), 17);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pos = widget.controller.currentPosition;
    final activePoi = widget.controller.activePoi;
    final allPois = widget.controller.allPois;
    // events list removed

    return Scaffold(
      backgroundColor: const Color(0xFFEFEFEF),
      body: Stack(
        children: [
          // ── Map ────────────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: pos != null
                  ? LatLng(pos.latitude, pos.longitude)
                  : LatLng(widget.controller.destination.centerLatitude,
                      widget.controller.destination.centerLongitude),
              initialZoom: widget.controller.destination.defaultZoom,
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture && _followUser) {
                  setState(() => _followUser = false);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.dulo.notmiss',
                tileProvider: NetworkTileProvider(),
              ),
              MarkerLayer(
                markers: [
                  ...allPois.map((p) => _buildPoiMarker(
                        p,
                        isActive: p.id == activePoi?.id,
                        isTriggered:
                            widget.controller.triggeredPoiIds.contains(p.id),
                      )),
                  if (pos != null) _buildUserMarker(pos),
                ],
              ),
            ],
          ),

          // ── Stryiskyi Park Testing / Activation Button ──────────────
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 16,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(20),
              color: Colors.white,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _showStryiskyiParkTestDialog(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: widget.controller.isSimulating
                          ? Colors.orange.shade800
                          : const Color(0xFF2E7D32),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.controller.isSimulating
                            ? Icons.play_circle_fill
                            : Icons.park_rounded,
                        color: widget.controller.isSimulating
                            ? Colors.orange.shade800
                            : const Color(0xFF2E7D32),
                        size: 20,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        widget.controller.isSimulating
                            ? 'Симуляція...'
                            : 'Стрийський парк (тест)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: widget.controller.isSimulating
                              ? Colors.orange.shade900
                              : const Color(0xFF1B5E20),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Status/Error Message Banner ─────────────────────────
          if (widget.controller.statusMessage != null && widget.controller.status != WalkStatus.walking)
            Positioned(
              top: MediaQuery.of(context).padding.top + 68,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.red.shade200, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withValues(alpha: 0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade700, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.controller.statusMessage!,
                        style: TextStyle(
                          color: Colors.red.shade900,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Map Controls & Walk HUD bottom panel ────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Floating controls anchored directly above the card
                  Padding(
                    padding: const EdgeInsets.only(right: 16, bottom: 12),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Compass reset (only shows if map is rotated)
                          StreamBuilder<MapEvent>(
                            stream: _mapController.mapEventStream,
                            builder: (ctx, snap) {
                              double rotation = 0.0;
                              try {
                                rotation = _mapController.camera.rotation;
                              } catch (_) {}
                              if (rotation == 0.0) return const SizedBox.shrink();
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12.0),
                                child: FloatingActionButton(
                                  heroTag: 'walkResetNorth',
                                  backgroundColor: Colors.white,
                                  elevation: 4,
                                  onPressed: () => _mapController.rotate(0),
                                  child: Transform.rotate(
                                    angle: -rotation * (3.14159 / 180),
                                    child: const Icon(Icons.explore, color: Colors.red, size: 28),
                                  ),
                                ),
                              );
                            },
                          ),
                          // Locate User Button
                          FloatingActionButton(
                            heroTag: 'walkLocateMe',
                            backgroundColor: Colors.white,
                            elevation: 4,
                            onPressed: _locateMe,
                            child: Icon(
                              pos != null && _followUser
                                  ? Icons.my_location
                                  : Icons.location_searching,
                              color: _followUser ? Colors.blue : Colors.grey.shade600,
                              size: 28,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Bottom card
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (activePoi != null)
                          _buildActivePoiCard(activePoi)
                        else
                          _buildIdleCard(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivePoiCard(Poi poi) {
    final isPlaying = widget.controller.isPlaying;
    final isPaused = widget.controller.isAudioPaused;
    final isAudioActive = isPlaying || isPaused;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: isAudioActive
                      ? (isPaused ? Colors.amber.shade50 : _kGreen.withValues(alpha: 0.15))
                      : _kGreen.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isAudioActive
                      ? (isPaused ? Icons.pause_circle_outline : Icons.volume_up)
                      : Icons.headphones,
                  color: isPaused ? Colors.amber.shade800 : _kGreen,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      poi.name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                      ),
                    ),
                    if (widget.controller.statusMessage != null && widget.controller.statusMessage!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        widget.controller.statusMessage!,
                        style: TextStyle(
                          fontSize: 16,
                          color: isPaused ? Colors.amber.shade900 : _kGreen.withValues(alpha: 0.8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (widget.controller.backgroundActivity.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              widget.controller.backgroundActivity,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.blue.shade700,
                                fontStyle: FontStyle.italic,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (poi.shortDescription.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              poi.shortDescription,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.black87,
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 20),
          // Audio Playback Controls (Pause / Resume / Stop / Play)
          if (isAudioActive) ...[
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      if (isPlaying) {
                        widget.controller.pauseAudio();
                      } else {
                        widget.controller.resumeAudio();
                      }
                    },
                    icon: Icon(
                      isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded,
                      size: 22,
                    ),
                    label: Text(
                      isPlaying ? 'Пауза' : 'Продовжити',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isPlaying ? Colors.amber.shade800 : _kGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 2,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => widget.controller.stopAudio(),
                    icon: const Icon(Icons.stop_circle_outlined, size: 22),
                    label: const Text(
                      'Зупинити',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _showAiChatSheet(context, poi),
              icon: const Icon(Icons.auto_awesome, size: 20),
              label: const Text(
                'Запитати ШІ про це місце',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: _kGreen,
                side: const BorderSide(color: _kGreen, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ] else ...[
            ElevatedButton.icon(
              onPressed: () {
                widget.controller.playNarrationForPoi(poi);
              },
              icon: const Icon(Icons.volume_up_rounded, size: 22),
              label: const Text(
                'Прослухати розповідь',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 2,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _showAiChatSheet(context, poi),
              icon: const Icon(Icons.auto_awesome, size: 20),
              label: const Text(
                'Запитати ШІ про це місце',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey.shade800,
                side: BorderSide(color: Colors.grey.shade300),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIdleCard() {
    final isPlaying = widget.controller.isPlaying;
    final isPaused = widget.controller.isAudioPaused;
    final isAudioActive = isPlaying || isPaused;
    final isWalking = widget.controller.status == WalkStatus.walking;

    // Build visited POIs list — all triggered POIs that are not currently active
    final visitedPois = isWalking
        ? widget.controller.allPois
            .where((p) =>
                widget.controller.triggeredPoiIds.contains(p.id) &&
                p.id != widget.controller.activePoi?.id)
            .toList()
        : <Poi>[];

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: isAudioActive
                      ? (isPaused ? Colors.amber.shade50 : _kGreen.withValues(alpha: 0.15))
                      : Colors.blue.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isAudioActive
                      ? (isPaused ? Icons.pause_circle_outline : Icons.volume_up)
                      : Icons.directions_walk,
                  color: isAudioActive
                      ? (isPaused ? Colors.amber.shade800 : _kGreen)
                      : Colors.blue.shade700,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isAudioActive
                          ? (isPaused ? 'Озвучення на паузі' : 'Грає розповідь гіда')
                          : 'Шукаємо цікаві місця...',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (widget.controller.statusMessage != null && widget.controller.statusMessage!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        widget.controller.statusMessage!,
                        style: TextStyle(
                          fontSize: 16,
                          color: isAudioActive ? Colors.black87 : Colors.black54,
                          fontWeight: isAudioActive ? FontWeight.w500 : FontWeight.normal,
                        ),
                      ),
                    ],
                    if (widget.controller.backgroundActivity.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              widget.controller.backgroundActivity,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.blue.shade700,
                                fontStyle: FontStyle.italic,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (isAudioActive) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      if (isPlaying) {
                        widget.controller.pauseAudio();
                      } else {
                        widget.controller.resumeAudio();
                      }
                    },
                    icon: Icon(
                      isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded,
                      size: 20,
                    ),
                    label: Text(
                      isPlaying ? 'Пауза' : 'Продовжити',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isPlaying ? Colors.amber.shade800 : _kGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => widget.controller.stopAudio(),
                    icon: const Icon(Icons.stop_circle_outlined, size: 20),
                    label: const Text(
                      'Зупинити',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
            ),
          ],

          // ── Visited POIs — horizontal scrollable list ────────────────────
          if (visitedPois.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.check_circle_outline, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Text(
                  'Відвідані місця (${visitedPois.length}):',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: visitedPois.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final poi = visitedPois[index];
                  return ActionChip(
                    avatar: const Icon(Icons.place, size: 16),
                    label: Text(
                      poi.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () => _showPoiDetails(context, poi),
                    backgroundColor: Colors.grey.shade100,
                    side: BorderSide(color: Colors.grey.shade300),
                    labelStyle: const TextStyle(fontSize: 13),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showStryiskyiParkTestDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E7D32).withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.park, color: Color(0xFF2E7D32), size: 28),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Стрийський парк',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '15 авторських точок з розповідями',
                          style: TextStyle(fontSize: 13, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Option 1: Move map to park
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE8F5E9),
                  child: Icon(Icons.map, color: Color(0xFF2E7D32)),
                ),
                title: const Text('Показати парк на карті', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Центрувати карту на парку (49.8228, 24.0264)'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mapController.move(
                    LatLng(widget.controller.destination.centerLatitude, widget.controller.destination.centerLongitude),
                    16.0,
                  );
                },
              ),
              const Divider(height: 16),
              // Option 2: Reset / enable points
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE8F5E9),
                  child: Icon(Icons.refresh, color: Color(0xFF2E7D32)),
                ),
                title: const Text('Увімкнути / скинути всі 15 точок', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Скидає статус відвіданих, робить усі точки активними'),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.controller.resetStryiskyiParkPois();
                },
              ),
              const Divider(height: 16),
              // Option 3: Simulation for background test
              if (!widget.controller.isSimulating) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: Colors.orange.shade50,
                    child: Icon(Icons.play_circle_fill, color: Colors.orange.shade800),
                  ),
                  title: const Text('Запустити тест фонового режиму (симуляція)', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Покроково переміщує між точками кожні 12 сек. Можна вимкнути екран і слухати!'),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.controller.startStryiskyiParkSimulation(stepIntervalSeconds: 12);
                  },
                ),
              ] else ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: Colors.red.shade50,
                    child: Icon(Icons.stop_circle, color: Colors.red.shade700),
                  ),
                  title: const Text('Зупинити симуляцію', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Повернутися до реального сигналу GPS'),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.controller.stopSimulation();
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _showAiChatSheet(BuildContext context, Poi poi) {
    _showAiChatModal(context, widget.controller, poi);
  }

  Marker _buildPoiMarker(Poi poi,
      {required bool isActive, required bool isTriggered}) {
    Color color = const Color(0xFF2E7D32); // Default green
    if (isActive) color = Colors.orange;
    if (isTriggered && !isActive) color = Colors.grey.shade400;

    return Marker(
      point: LatLng(poi.latitude, poi.longitude),
      width: 36,
      height: 36,
      child: GestureDetector(
        onTap: () => _showPoiDetails(context, poi),
        onDoubleTap: () => _showPoiDetails(context, poi),
        onLongPress: () => _showPoiDetails(context, poi),
        child: Tooltip(
          message: poi.name,
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Icon(
              (isTriggered && !isActive) ? Icons.check : Icons.place,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }

  void _showPoiDetails(BuildContext context, Poi poi) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _PoiDetailsSheet(
        controller: widget.controller,
        poi: poi,
      ),
    );
  }

  Marker _buildUserMarker(Position pos) {
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
            angle: heading * math.pi / 180,
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

/// Dynamic bottom sheet that displays POI details, the AI narration script,
/// facts, queue progress, and an instant audio playback button.
class _PoiDetailsSheet extends StatefulWidget {
  final WalkController controller;
  final Poi poi;

  const _PoiDetailsSheet({required this.controller, required this.poi});

  @override
  State<_PoiDetailsSheet> createState() => _PoiDetailsSheetState();
}

class _PoiDetailsSheetState extends State<_PoiDetailsSheet> {
  bool _isRequesting = false;

  bool _isTrivial(String? s) {
    if (s == null || s.trim().isEmpty) return true;
    final trimmed = s.trim().toLowerCase();
    const trivialOsmValues = {
      'library', 'artwork', 'monument', 'fountain', 'viewpoint',
      'museum', 'ruins', 'park', 'attraction', 'memorial'
    };
    if (trivialOsmValues.contains(trimmed)) return true;
    return trimmed.length < 15 && !trimmed.contains(' ');
  }

  @override
  void initState() {
    super.initState();
    _checkAndTriggerResearch();
  }

  void _checkAndTriggerResearch() {
    final updatedPoi = widget.controller.getUpdatedPoi(widget.poi);
    final enriched = widget.controller.getEnrichedPoi(widget.poi.id);

    final hasNarration = (enriched?.narrationText?.isNotEmpty == true || updatedPoi.narrationText.isNotEmpty);
    final rawDesc = (enriched?.shortDescription?.isNotEmpty == true)
        ? enriched!.shortDescription!
        : updatedPoi.shortDescription;
    final hasRichDesc = !_isTrivial(rawDesc);
    final hasFacts = (enriched?.keyFacts.isNotEmpty == true || updatedPoi.facts.isNotEmpty);

    final hasCompleteData = hasNarration && hasRichDesc && hasFacts;

    if (!hasCompleteData && !_isRequesting) {
      _isRequesting = true;
      widget.controller.researchPoiNow(widget.poi).whenComplete(() {
        if (mounted) {
          setState(() => _isRequesting = false);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, child) {
        final enriched = widget.controller.getEnrichedPoi(widget.poi.id);
        final updatedPoi = widget.controller.getUpdatedPoi(widget.poi);
        final queuePos = widget.controller.getQueuePosition(widget.poi.id);

        final narration = (enriched?.narrationText?.isNotEmpty == true)
            ? enriched!.narrationText!
            : updatedPoi.narrationText;

        final rawDesc = (enriched?.shortDescription?.isNotEmpty == true)
            ? enriched!.shortDescription!
            : updatedPoi.shortDescription;
        final description = _isTrivial(rawDesc) ? '' : rawDesc;

        final facts = (enriched?.keyFacts.isNotEmpty == true)
            ? enriched!.keyFacts.map((f) => f.fact).toList()
            : updatedPoi.facts;

        final isPlayingThisPoi = widget.controller.isPlaying &&
            widget.controller.activePoi?.id == widget.poi.id;
        final isPausedThisPoi = widget.controller.isAudioPaused &&
            widget.controller.activePoi?.id == widget.poi.id;
        final isAudioActiveThisPoi = isPlayingThisPoi || isPausedThisPoi;
        final isAlreadyTriggered =
            widget.controller.triggeredPoiIds.contains(widget.poi.id);

        final isProcessing = _isRequesting ||
            queuePos == 0 ||
            (enriched != null && enriched.researchStatus == ResearchStatus.inProgress);

        // Determine badge label
        String? badgeLabel;
        if (enriched != null && enriched.sources.isNotEmpty) {
          final firstSource = enriched.sources.first.type;
          badgeLabel = firstSource == 'ai' ? 'ШІ-гід' : 'Вікіпедія';
        } else if (updatedPoi.narrationText.isNotEmpty) {
          badgeLabel = 'Аудіогід';
        }

        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.82,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                // Scrollable content
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Title + Badge Row
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                widget.poi.name,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  height: 1.25,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                            if (badgeLabel != null) ...[
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.blue.shade200),
                                ),
                                child: Text(
                                  badgeLabel,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue.shade800,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Queue / Processing Banner
                        if (isProcessing && (narration.isEmpty || description.isEmpty)) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.amber.shade300),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2.5),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        queuePos > 0
                                            ? 'Об\'єкт у черзі на дослідження (позиція: $queuePos)...'
                                            : 'ШІ та Вікіпедія готують розповідь та факти...',
                                        style: TextStyle(
                                          fontSize: 15,
                                          color: Colors.amber.shade900,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Зачекайте 1-2 секунди, інформація завантажується автоматично.',
                                        style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        // 🎧 AI Narration Card
                        if (narration.isNotEmpty) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 18),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F8E9), // Soft green tint
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: const Color(0xFFA5D6A7)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.03),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.headphones, color: Color(0xFF2E7D32), size: 22),
                                    const SizedBox(width: 8),
                                    const Expanded(
                                      child: Text(
                                        'Розповідь аудіогіда:',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF1B5E20),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  narration,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: Color(0xFF1B3B1B),
                                    height: 1.45,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                if (isAudioActiveThisPoi) ...[
                                  Row(
                                    children: [
                                      Expanded(
                                        child: ElevatedButton.icon(
                                          onPressed: () {
                                            if (isPlayingThisPoi) {
                                              widget.controller.pauseAudio();
                                            } else {
                                              widget.controller.resumeAudio();
                                            }
                                          },
                                          icon: Icon(
                                            isPlayingThisPoi
                                                ? Icons.pause_circle_filled_rounded
                                                : Icons.play_circle_filled_rounded,
                                            size: 20,
                                          ),
                                          label: Text(
                                            isPlayingThisPoi ? 'Пауза' : 'Продовжити',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                            ),
                                          ),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: isPlayingThisPoi
                                                ? Colors.amber.shade800
                                                : const Color(0xFF2E7D32),
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(vertical: 12),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: ElevatedButton.icon(
                                          onPressed: () => widget.controller.stopAudio(),
                                          icon: const Icon(Icons.stop_circle_outlined, size: 20),
                                          label: const Text(
                                            'Зупинити',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                            ),
                                          ),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.red.shade700,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(vertical: 12),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ] else ...[
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () {
                                        widget.controller.playNarrationForPoi(widget.poi);
                                      },
                                      icon: Icon(
                                        isAlreadyTriggered
                                            ? Icons.replay_rounded
                                            : Icons.volume_up,
                                        size: 20,
                                      ),
                                      label: Text(
                                        isAlreadyTriggered
                                            ? 'Прослухати знову'
                                            : 'Прослухати зараз',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF2E7D32),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ] else if (!isProcessing) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 18),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F8E9),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: const Color(0xFFA5D6A7)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Row(
                                  children: [
                                    Icon(Icons.headphones, color: Color(0xFF2E7D32), size: 22),
                                    SizedBox(width: 8),
                                    Text(
                                      'Аудіогід від ШІ:',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF1B5E20),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'ШІ може озвучити розповідь про це місце для вас прямо зараз.',
                                  style: TextStyle(fontSize: 14, color: Color(0xFF1B3B1B)),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: widget.controller.isAudioActive
                                        ? null
                                        : () {
                                            widget.controller.playNarrationForPoi(widget.poi);
                                          },
                                    icon: const Icon(Icons.volume_up, size: 20),
                                    label: const Text(
                                      'Прослухати розповідь ШІ',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF2E7D32),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        // 🏛 Description Section
                        if (description.isNotEmpty) ...[
                          const Text(
                            'Про місце:',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            description,
                            style: const TextStyle(
                              fontSize: 15,
                              color: Colors.black87,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // 💡 Key Facts Section
                        if (facts.isNotEmpty) ...[
                          Text(
                            'Цікаві факти:',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey.shade800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...facts.map((f) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '• ',
                                      style: TextStyle(
                                        color: Colors.blue.shade700,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        f,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Colors.black87,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              )),
                          const SizedBox(height: 16),
                        ],

                        // Fallback message if no data at all yet
                        if (!isProcessing && narration.isEmpty && description.isEmpty && facts.isEmpty) ...[
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.info_outline, size: 20, color: Colors.grey.shade700),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Цей об\'єкт знайдено на карті',
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.grey.shade800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'У відкритих реєстрах стаття відсутня, проте ШІ може підготувати опис та розповідь прямо зараз.',
                                  style: TextStyle(fontSize: 14, color: Colors.grey.shade600, height: 1.35),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: () {
                                    setState(() => _isRequesting = true);
                                    widget.controller.researchPoiNow(widget.poi).whenComplete(() {
                                      if (mounted) setState(() => _isRequesting = false);
                                    });
                                  },
                                  icon: const Icon(Icons.auto_awesome, size: 18),
                                  label: const Text('Згенерувати опис ШІ зараз'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ],
                    ),
                  ),
                ),

                // Ask AI Button
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7D32),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 1,
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        _showAiChatModal(context, widget.controller, widget.poi);
                      },
                      icon: const Icon(Icons.auto_awesome, size: 20),
                      label: const Text(
                        'Запитати ШІ про це місце',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),

                // Bottom Close Button
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey.shade800,
                        side: BorderSide(color: Colors.grey.shade300),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Закрити',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Helper to open the AI Chat Bottom Sheet.
void _showAiChatModal(BuildContext context, WalkController controller, Poi poi) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _AiChatSheet(
      controller: controller,
      poi: poi,
    ),
  );
}

/// Single chat message model.
class _ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  _ChatMessage({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Interactive AI Chat Bottom Sheet for querying Gemini about a POI.
class _AiChatSheet extends StatefulWidget {
  final WalkController controller;
  final Poi poi;

  const _AiChatSheet({
    required this.controller,
    required this.poi,
  });

  @override
  State<_AiChatSheet> createState() => _AiChatSheetState();
}

class _AiChatSheetState extends State<_AiChatSheet> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  bool _isLoading = false;
  String? _currentlySpeakingText;

  final List<String> _quickQuestions = const [
    'Коли це з\'явилося?',
    'Чим особливе це місце?',
    'Хто автор чи архітектор?',
    'Розкажи цікавий факт',
    'Яка тут історія чи легенда?',
  ];

  @override
  void initState() {
    super.initState();
    _messages.add(
      _ChatMessage(
        text: 'Вітаю! Я ваш ШІ-гід. Запитайте мене будь-що про «${widget.poi.name}»!',
        isUser: false,
      ),
    );
  }

  @override
  void dispose() {
    if (_currentlySpeakingText != null) {
      widget.controller.stopAudio();
    }
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage(String text) async {
    final query = text.trim();
    if (query.isEmpty || _isLoading) return;

    _textController.clear();
    setState(() {
      _messages.add(_ChatMessage(text: query, isUser: true));
      _isLoading = true;
    });

    _scrollToBottom();

    try {
      final answer = await widget.controller.askAiAboutPoi(widget.poi, query);
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(text: answer, isUser: false));
        _isLoading = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(
          _ChatMessage(
            text: 'Вибачте, виникла помилка зв\'язку з ШІ: $e',
            isUser: false,
          ),
        );
        _isLoading = false;
      });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _speakMessage(String text) {
    if (_currentlySpeakingText == text) {
      widget.controller.stopAudio();
      setState(() {
        _currentlySpeakingText = null;
      });
      return;
    }

    setState(() {
      _currentlySpeakingText = text;
    });

    widget.controller.speakText(text).whenComplete(() {
      if (mounted) {
        setState(() {
          if (_currentlySpeakingText == text) {
            _currentlySpeakingText = null;
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final screenHeight = MediaQuery.of(context).size.height;
    final modalHeight = (screenHeight * 0.85)
        .clamp(280.0, math.max(280.0, screenHeight - bottomInset - 40))
        .toDouble();

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: modalHeight,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE8F5E9),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.auto_awesome,
                      color: Color(0xFF2E7D32),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.poi.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'ШІ-екскурсовод • Gemini',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 24),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Quick suggestion chips
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemCount: _quickQuestions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final q = _quickQuestions[index];
                  return InkWell(
                    onTap: _isLoading ? null : () => _sendMessage(q),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Text(
                        q,
                        style: TextStyle(
                          fontSize: 13,
                          color: _isLoading ? Colors.grey.shade400 : Colors.grey.shade800,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),

            // Message history list
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                itemCount: _messages.length + (_isLoading ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == _messages.length && _isLoading) {
                    return _buildLoadingBubble();
                  }
                  final msg = _messages[index];
                  return _buildMessageBubble(msg);
                },
              ),
            ),

            // Input Area
            Container(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 10,
                bottom: MediaQuery.of(context).padding.bottom > 0
                    ? MediaQuery.of(context).padding.bottom + 8
                    : 14,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    offset: const Offset(0, -2),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _sendMessage,
                      decoration: InputDecoration(
                        hintText: 'Запитайте про «${widget.poi.name}»...',
                        hintStyle: TextStyle(
                          fontSize: 15,
                          color: Colors.grey.shade500,
                        ),
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                      ),
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Send button
                  GestureDetector(
                    onTap: () => _sendMessage(_textController.text),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _isLoading
                            ? Colors.grey.shade400
                            : const Color(0xFF2E7D32),
                        shape: BoxShape.circle,
                        boxShadow: [
                          if (!_isLoading)
                            BoxShadow(
                              color: const Color(0xFF2E7D32).withValues(alpha: 0.35),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                        ],
                      ),
                      child: _isLoading
                          ? const Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : const Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(_ChatMessage msg) {
    if (msg.isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Color(0xFF2E7D32),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Text(
              msg.text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                height: 1.35,
              ),
            ),
          ),
        ),
      );
    } else {
      final isSpeaking = _currentlySpeakingText == msg.text;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F9F5),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
              ),
              border: Border.all(color: const Color(0xFFC8E6C9)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  msg.text,
                  style: const TextStyle(
                    color: Color(0xFF1B3B1B),
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () => _speakMessage(msg.text),
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isSpeaking
                                  ? Icons.stop_circle_outlined
                                  : Icons.volume_up_outlined,
                              size: 18,
                              color: isSpeaking
                                  ? Colors.red.shade700
                                  : const Color(0xFF2E7D32),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isSpeaking ? 'Зупинити' : 'Озвучити',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isSpeaking
                                    ? Colors.red.shade700
                                    : const Color(0xFF2E7D32),
                              ),
                            ),
                          ],
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
    }
  }

  Widget _buildLoadingBubble() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F9F5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFC8E6C9)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF2E7D32),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'ШІ думає над відповіддю...',
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
