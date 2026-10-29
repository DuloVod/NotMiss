import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:latlong2/latlong.dart';
import '../../models/poi.dart';
import '../../models/enriched_poi.dart';
import '../../models/chat_message.dart';
import '../../services/poi_category_service.dart';
import '../walk_controller.dart';
import '../theme/app_theme.dart';
import 'package:geolocator/geolocator.dart'; // For Position

/// Main unified screen that immediately starts the walk and shows the HUD.
class MainScreen extends StatefulWidget {
  final WalkController controller;

  const MainScreen({super.key, required this.controller});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  LatLng? _lastPos;
  bool _followUser = true; // auto-follow; turns off if user pans manually

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_update);
    _mapController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When returning from iOS/Android Settings, auto-start if permission was granted
    if (state == AppLifecycleState.resumed && widget.controller.status != WalkStatus.walking) {
      widget.controller.startWalk();
    }
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

    return Scaffold(
      backgroundColor: NmColors.background,
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

          // ── Status/Error Message Banner (idle/warning only) ─────
          if (widget.controller.statusMessage != null && widget.controller.status == WalkStatus.idle)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: NmColors.cream,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(Icons.location_off_outlined, color: NmColors.ink, size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.controller.statusMessage!,
                        style: TextStyle(
                          color: NmColors.ink,
                          fontSize: 14,
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
                          // Compass reset & orientation indicator (always accessible)
                          StreamBuilder<MapEvent>(
                            stream: _mapController.mapEventStream,
                            builder: (ctx, snap) {
                              double rotation = 0.0;
                              try {
                                rotation = _mapController.camera.rotation;
                              } catch (_) {}
                              final isRotated = rotation.abs() > 0.5;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12.0),
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: FloatingActionButton(
                                    heroTag: 'walkResetNorth',
                                    backgroundColor: Colors.white,
                                    elevation: 4,
                                    tooltip: 'Орієнтувати на північ',
                                    onPressed: () => _mapController.rotate(0.0),
                                    child: Transform.rotate(
                                      angle: -rotation * (3.141592653589793 / 180),
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Icon(
                                            Icons.navigation,
                                            color: isRotated ? NmColors.compassRed : NmColors.muted,
                                            size: 24,
                                          ),
                                          Positioned(
                                            top: 2,
                                            child: Text(
                                              'N',
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.w600,
                                                color: isRotated ? NmColors.compassRed : NmColors.muted,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          // Locate User Button
                          SizedBox(
                            width: 48,
                            height: 48,
                            child: FloatingActionButton(
                              heroTag: 'walkLocateMe',
                              backgroundColor: Colors.white,
                              elevation: 4,
                              tooltip: 'Моє розташування',
                              onPressed: _locateMe,
                              child: Icon(
                                pos != null && _followUser
                                    ? Icons.my_location
                                    : Icons.location_searching,
                                color: _followUser ? NmColors.userDot : NmColors.muted,
                                size: 26,
                              ),
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
    final displayText = (poi.narrationText.isNotEmpty)
        ? poi.narrationText
        : poi.shortDescription;

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
                  color: NmColors.cream,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isAudioActive
                      ? (isPaused ? Icons.pause_circle_outline : Icons.volume_up)
                      : Icons.headphones,
                  color: NmColors.ink,
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
                      style: NmText.title(22),
                    ),
                    if (widget.controller.statusMessage != null && widget.controller.statusMessage!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        widget.controller.statusMessage!,
                        style: TextStyle(
                          fontSize: 16,
                          color: NmColors.ink,
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
                                color: NmColors.muted,
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
          // Narration or Description Card (with quick open to full sheet)
          if (displayText.isNotEmpty) ...[
            const SizedBox(height: 14),
            InkWell(
              onTap: () => _showPoiDetails(context, poi),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: NmColors.cream,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          poi.narrationText.isNotEmpty ? Icons.auto_awesome : Icons.info_outline,
                          size: 16,
                          color: NmColors.ink,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          poi.narrationText.isNotEmpty ? 'Текст розповіді гіда:' : 'Про об\'єкт:',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: NmColors.ink,
                          ),
                        ),
                        const Spacer(),
                        const Text(
                          'Читати все ↗',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: NmColors.ink,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      displayText,
                      style: const TextStyle(
                        fontSize: 14,
                        color: NmColors.ink,
                        height: 1.4,
                      ),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
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
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: NmButtons.secondary(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => widget.controller.stopAudio(),
                    icon: const Icon(Icons.stop_circle_outlined, size: 22),
                    label: const Text(
                      'Зупинити',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: NmButtons.destructive(),
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
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              style: NmButtons.primary(),
            ),
          ] else ...[
            if (widget.controller.isProcessing && widget.controller.activePoi?.id == poi.id) ...[
              ElevatedButton.icon(
                onPressed: null,
                icon: const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
                label: const Text(
                  'Готуємо розповідь…',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                style: NmButtons.primary(),
              ),
            ] else ...[
              ElevatedButton.icon(
                onPressed: () {
                  widget.controller.playNarrationForPoi(poi);
                },
                icon: const Icon(Icons.volume_up_rounded, size: 22),
                label: const Text(
                  'Прослухати розповідь',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                style: NmButtons.primary(),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _showAiChatSheet(context, poi),
              icon: const Icon(Icons.auto_awesome, size: 20),
              label: const Text(
                'Запитати ШІ про це місце',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              style: NmButtons.secondary(),
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

    if (!isWalking) {
      final isStopped = widget.controller.status == WalkStatus.stopped;
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
                    color: NmColors.cream,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isStopped ? Icons.flag_outlined : Icons.location_on_outlined,
                    color: NmColors.ink,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isStopped ? 'Прогулянку завершено' : 'Потрібна геолокація',
                        style: NmText.title(20),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.controller.statusMessage ??
                            (isStopped
                                ? 'Ви завжди можете розпочати новий маршрут!'
                                : 'Для роботи аудіогіда надайте доступ до геопозиції.'),
                        style: const TextStyle(
                          fontSize: 14,
                          color: NmColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => widget.controller.startWalk(),
                    icon: const Icon(Icons.play_arrow_rounded, size: 22),
                    label: Text(
                      isStopped ? 'Почати нову прогулянку' : 'Почати прогулянку',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: NmButtons.primary(),
                  ),
                ),
                if (!isStopped) ...[
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () => Geolocator.openAppSettings(),
                    style: NmButtons.secondary(),
                    child: const Icon(Icons.settings_outlined, size: 22),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    // Walking mode
    final visitedPois = widget.controller.allPois
        .where((p) =>
            widget.controller.triggeredPoiIds.contains(p.id) &&
            p.id != widget.controller.activePoi?.id)
        .toList();

    Poi? nearestPoi;
    double? nearestDist;
    final pos = widget.controller.currentPosition;
    if (pos != null) {
      for (final p in widget.controller.allPois) {
        if (!widget.controller.triggeredPoiIds.contains(p.id)) {
          final d = Geolocator.distanceBetween(
            pos.latitude, pos.longitude, p.latitude, p.longitude,
          );
          if (nearestDist == null || d < nearestDist) {
            nearestDist = d;
            nearestPoi = p;
          }
        }
      }
    }

    String idleTitle = 'Шукаємо цікаві місця...';
    String? idleSubtitle = widget.controller.statusMessage;

    if (!isAudioActive) {
      if (widget.controller.allPois.isEmpty) {
        idleTitle = 'Шукаємо цікаві місця...';
        idleSubtitle = 'Завантажуємо пам\'ятки з карти поруч з вами…';
      } else if (nearestPoi != null && nearestDist != null) {
        idleTitle = 'Гід на зв\'язку';
        idleSubtitle = 'Найближче: ${nearestPoi.name} (~${nearestDist.round()} м)';
      } else {
        idleTitle = 'Гід на зв\'язку';
        idleSubtitle = 'Пам\'яток поруч: ${widget.controller.allPois.length} (підійдіть ближче)';
      }
    }

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
                  color: NmColors.cream,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isAudioActive
                      ? (isPaused ? Icons.pause_circle_outline : Icons.volume_up)
                      : Icons.directions_walk,
                  color: NmColors.ink,
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
                          : idleTitle,
                      style: NmText.title(20),
                    ),
                    if (idleSubtitle != null && idleSubtitle.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        idleSubtitle,
                        style: TextStyle(
                          fontSize: 15,
                          color: isAudioActive ? NmColors.ink : NmColors.muted,
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
                                color: NmColors.muted,
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
              if (!isAudioActive) ...[
                IconButton(
                  tooltip: 'Оновити об\'єкти на карті',
                  icon: const Icon(Icons.refresh_rounded, color: NmColors.muted),
                  onPressed: () => widget.controller.reloadOsmPois(),
                ),
              ],
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
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: NmButtons.secondary(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => widget.controller.stopAudio(),
                    icon: const Icon(Icons.stop_circle_outlined, size: 20),
                    label: const Text(
                      'Зупинити',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: NmButtons.destructive(),
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
                Icon(Icons.check_circle_outline, size: 16, color: NmColors.muted),
                const SizedBox(width: 6),
                Text(
                  'Відвідані місця (${visitedPois.length}):',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: NmColors.muted,
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
                    backgroundColor: NmColors.background,
                    side: BorderSide(color: NmColors.sand),
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

  void _showAiChatSheet(BuildContext context, Poi poi) {
    _showAiChatModal(context, widget.controller, poi);
  }

  Marker _buildPoiMarker(Poi poi,
      {required bool isActive, required bool isTriggered}) {
    Color color = NmColors.ink; // Unvisited place
    if (isActive) color = NmColors.ochre;
    if (isTriggered && !isActive) color = NmColors.stone;

    return Marker(
      point: LatLng(poi.latitude, poi.longitude),
      width: 48,
      height: 48,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          try {
            _mapController.move(LatLng(poi.latitude, poi.longitude), _mapController.camera.zoom);
          } catch (_) {}
          _showPoiDetails(context, poi);
        },
        child: Center(
          child: Tooltip(
            message: poi.name,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                (isTriggered && !isActive) ? Icons.check : Icons.place,
                color: Colors.white,
                size: 18,
              ),
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
                  color: NmColors.userDot,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: NmColors.userDot.withValues(alpha: 0.4),
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
                    color: NmColors.userDot.withValues(alpha: 0.8),
                    size: 28,
                  ),
                ),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: NmColors.userDot,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: NmColors.userDot.withValues(alpha: 0.4),
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
    final hasRichDesc = !PoiCategoryService.isTrivialDescription(rawDesc);
    final hasFacts = (enriched?.keyFacts.isNotEmpty == true || updatedPoi.facts.isNotEmpty);

    final hasFallback = enriched?.hasFallbackContent ?? false;
    final hasCompleteData = hasNarration && hasRichDesc && hasFacts && !hasFallback;
    final isAlreadyResearched = (enriched?.isResearchComplete == true) && !hasFallback;

    if ((!hasCompleteData || hasFallback) && !_isRequesting) {
      _isRequesting = true;
      widget.controller.researchPoiNow(widget.poi, force: hasFallback).whenComplete(() {
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
        final description = PoiCategoryService.isTrivialDescription(rawDesc) ? '' : rawDesc;

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

        final category = enriched?.category ?? PoiCategoryService().categorize(widget.poi.osmTags ?? {});
        final catLabel = PoiCategoryService.categoryLabelUk(category);
        final catEmoji = PoiCategoryService.categoryEmoji(category);

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
                    color: NmColors.sand,
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
                                style: NmText.title(28),
                              ),
                            ),
                            if (badgeLabel != null) ...[
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: NmColors.cream,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  badgeLabel,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: NmColors.ink,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: NmColors.cream,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '$catEmoji $catLabel',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: NmColors.ink,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),

                        // Queue / Processing Banner
                        if (isProcessing && (narration.isEmpty || description.isEmpty)) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: NmColors.cream,
                              borderRadius: BorderRadius.circular(16),
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
                                            : 'Шишка шукає інформацію про це місце (Вікіпедія, ШІ)...',
                                        style: TextStyle(
                                          fontSize: 15,
                                          color: NmColors.ink,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Зачекайте 1-2 секунди, інформація завантажується автоматично.',
                                        style: TextStyle(fontSize: 13, color: NmColors.muted),
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
                              color: NmColors.cream, // Soft cream panel
                              borderRadius: BorderRadius.circular(16),
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
                                    const Icon(Icons.headphones, color: NmColors.ink, size: 22),
                                    const SizedBox(width: 8),
                                    const Expanded(
                                      child: Text(
                                        'Розповідь аудіогіда:',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: NmColors.ink,
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
                                    color: NmColors.ink,
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
                                              fontWeight: FontWeight.w600,
                                              fontSize: 15,
                                            ),
                                          ),
                                          style: NmButtons.secondary(),
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
                                              fontWeight: FontWeight.w600,
                                              fontSize: 15,
                                            ),
                                          ),
                                          style: NmButtons.destructive(),
                                        ),
                                      ),
                                    ],
                                  ),
                                ] else ...[
                                  if (widget.controller.isProcessing && widget.controller.activePoi?.id == widget.poi.id) ...[
                                    SizedBox(
                                      width: double.infinity,
                                      child: ElevatedButton.icon(
                                        onPressed: null,
                                        icon: const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                        ),
                                        label: const Text(
                                          'Готуємо розповідь…',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 15,
                                          ),
                                        ),
                                        style: NmButtons.primary(),
                                      ),
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
                                            fontWeight: FontWeight.w600,
                                            fontSize: 15,
                                          ),
                                        ),
                                        style: NmButtons.primary(),
                                      ),
                                    ),
                                  ],
                                ],
                              ],
                            ),
                          ),
                        ] else if (!isProcessing) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 18),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: NmColors.cream,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Row(
                                  children: [
                                    Icon(Icons.headphones, color: NmColors.ink, size: 22),
                                    SizedBox(width: 8),
                                    Text(
                                      'Аудіогід від ШІ:',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: NmColors.ink,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'ШІ може озвучити розповідь про це місце для вас прямо зараз.',
                                  style: TextStyle(fontSize: 14, color: NmColors.ink),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: (widget.controller.isProcessing && widget.controller.activePoi?.id == widget.poi.id)
                                        ? null
                                        : () {
                                            widget.controller.playNarrationForPoi(widget.poi);
                                          },
                                    icon: (widget.controller.isProcessing && widget.controller.activePoi?.id == widget.poi.id)
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                          )
                                        : const Icon(Icons.volume_up, size: 20),
                                    label: Text(
                                      (widget.controller.isProcessing && widget.controller.activePoi?.id == widget.poi.id)
                                          ? 'Готуємо розповідь…'
                                          : 'Прослухати розповідь ШІ',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15,
                                      ),
                                    ),
                                    style: NmButtons.primary(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        // 🏛 Description Section
                        if (description.isNotEmpty) ...[
                          Text(
                            'Про місце',
                            style: NmText.title(18),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            description,
                            style: const TextStyle(
                              fontSize: 15,
                              color: NmColors.ink,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // 💡 Key Facts Section
                        if (facts.isNotEmpty) ...[
                          Text(
                            'Цікаві факти',
                            style: NmText.title(18),
                          ),
                          const SizedBox(height: 8),
                          ...facts.map((f) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '• ',
                                      style: const TextStyle(
                                        color: NmColors.ochre,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        f,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: NmColors.ink,
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
                              color: NmColors.background,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.info_outline, size: 20, color: NmColors.muted),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Цей об\'єкт знайдено на карті',
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: NmColors.ink,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'У відкритих реєстрах стаття відсутня, проте ШІ може підготувати опис та розповідь прямо зараз.',
                                  style: TextStyle(fontSize: 14, color: NmColors.muted, height: 1.35),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: () {
                                    setState(() => _isRequesting = true);
                                    widget.controller.researchPoiNow(widget.poi, force: true).whenComplete(() {
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
                      style: NmButtons.primary(),
                      onPressed: () {
                        Navigator.pop(context);
                        _showAiChatModal(context, widget.controller, widget.poi);
                      },
                      icon: const Icon(Icons.auto_awesome, size: 20),
                      label: const Text(
                        'Запитати ШІ про це місце',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
                      style: NmButtons.secondary(),
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Закрити',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
  List<ChatMessage> get _messages => widget.controller.getChatHistory(widget.poi.id);
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
    final history = widget.controller.getChatHistory(widget.poi.id);
    if (history.isEmpty) {
      widget.controller.addChatMessage(
        widget.poi.id,
        ChatMessage(
          text: 'Вітаю! Я ваш ШІ-гід. Запитайте мене будь-що про «${widget.poi.name}»!',
          isUser: false,
        ),
      );
    }
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
    widget.controller.addChatMessage(
      widget.poi.id,
      ChatMessage(text: query, isUser: true),
    );
    setState(() {
      _isLoading = true;
    });

    _scrollToBottom();

    try {
      final answer = await widget.controller.askAiAboutPoi(widget.poi, query);
      widget.controller.addChatMessage(
        widget.poi.id,
        ChatMessage(text: answer, isUser: false),
      );
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      _scrollToBottom();
    } catch (e) {
      widget.controller.addChatMessage(
        widget.poi.id,
        ChatMessage(
          text: 'Вибачте, виникла помилка зв\'язку з ШІ: $e',
          isUser: false,
        ),
      );
      if (!mounted) return;
      setState(() {
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
                color: NmColors.sand,
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
                      color: NmColors.cream,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.auto_awesome,
                      color: NmColors.ink,
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
                          style: NmText.title(20),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'ШІ-екскурсовод • Gemini',
                          style: TextStyle(
                            fontSize: 12,
                            color: NmColors.muted,
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
                        color: NmColors.background,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        q,
                        style: TextStyle(
                          fontSize: 13,
                          color: _isLoading ? NmColors.stone : NmColors.ink,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // Message history list
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                          color: NmColors.stone,
                        ),
                        filled: true,
                        fillColor: NmColors.background,
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
                            ? NmColors.stone
                            : NmColors.ink,
                        shape: BoxShape.circle,
                        boxShadow: [
                          if (!_isLoading)
                            BoxShadow(
                              color: NmColors.ink.withValues(alpha: 0.35),
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

  Widget _buildMessageBubble(ChatMessage msg) {
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
              color: NmColors.ink,
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
              color: NmColors.background,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  msg.text,
                  style: const TextStyle(
                    color: NmColors.ink,
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
                                  ? NmColors.ink
                                  : NmColors.muted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isSpeaking ? 'Зупинити' : 'Озвучити',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isSpeaking
                                    ? NmColors.ink
                                    : NmColors.muted,
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
            color: NmColors.background,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: NmColors.ink,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'ШІ думає над відповіддю...',
                style: TextStyle(
                  color: NmColors.muted,
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
