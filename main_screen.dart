import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:latlong2/latlong.dart';
import '../../models/poi.dart';
import '../../models/enriched_poi.dart';
import '../../models/chat_message.dart';
import '../../services/poi_category_service.dart';
import '../../l10n/app_lang.dart';
import '../../l10n/place_name.dart';
import '../../services/report_service.dart';
import '../../services/visited_store.dart';
import '../walk_controller.dart';
import '../spoken_text.dart';
import '../guide_status.dart';
import '../../services/text_quality.dart';
import '../poi_kind.dart';
import '../theme/app_theme.dart';
import '../theme/nm_widgets.dart';
import 'package:geolocator/geolocator.dart'; // For Position

/// The app's one screen.
///
/// Not walking: the start screen (first open) or the "walk finished" summary.
/// Walking: the map with a card at the bottom that follows the guide —
/// looking for places, preparing a story, playing it (or a mini-player when collapsed).
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

  /// The playing card is folded into a mini-player (map + one row).
  bool _collapsed = false;

  /// Which place the bottom card shows; a new place always opens unfolded.
  String? _cardPoiId;

  WalkController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_update);
    // The walk is not started here: the start screen asks first («Почати прогулянку»).
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
    widget.controller.setAppLifecycle(state);
    // Back from the phone's Settings after the location was refused: try again.
    // A finished walk is not restarted by itself — the user starts a new one.
    if (state == AppLifecycleState.resumed &&
        widget.controller.status == WalkStatus.idle &&
        widget.controller.guideStatus != null) {
      widget.controller.startWalk();
    }
  }

  void _update() {
    if (!mounted) return;
    final pos = widget.controller.currentPosition;
    if (pos != null &&
        _followUser &&
        widget.controller.status == WalkStatus.walking) {
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
        try {
          _mapController.move(newLatLng, zoom);
        } catch (_) {
          // The map is not laid out yet; the next position fix moves it.
        }
      }
    }
    setState(() {});
  }

  void _locateMe() {
    final pos = widget.controller.currentPosition;
    if (pos != null) {
      _followUser = true;
      // Centre on the user without touching the zoom the user has chosen.
      double zoom = 17;
      try {
        zoom = _mapController.camera.zoom;
      } catch (_) {}
      try {
        _mapController.move(LatLng(pos.latitude, pos.longitude), zoom);
      } catch (_) {}
    }
    setState(() {});
  }

  // ── Layout ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final pos = _c.currentPosition;
    final activePoi = _c.activePoi;
    final allPois = _c.allPois;
    final visitedIds = _c.visitedPoiIds;
    final listenedIds = _c.listenedPoiIds;
    final silentIds = _c.silentPoiIds;
    final walking = _c.status == WalkStatus.walking;

    if (activePoi?.id != _cardPoiId) {
      _cardPoiId = activePoi?.id;
      _collapsed = false;
    }

    final guideStatus = _c.guideStatus;
    final topInset = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: NmColors.background,
      body: Stack(
        children: [
          // ── Map (the real OpenStreetMap; only what sits on top is restyled) ──────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: pos != null
                  ? LatLng(pos.latitude, pos.longitude)
                  : LatLng(_c.destination.centerLatitude,
                      _c.destination.centerLongitude),
              initialZoom: _c.destination.defaultZoom,
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
                        isTriggered: visitedIds.contains(p.id),
                        isListened: listenedIds.contains(p.id),
                        isSilent: silentIds.contains(p.id),
                      )),
                  if (pos != null) _buildUserMarker(pos),
                ],
              ),
            ],
          ),

          if (walking) ...[
            // Soft cream fade under the top bar so it reads over any map.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topInset + 70,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        NmColors.background.withValues(alpha: 0.95),
                        NmColors.background.withValues(alpha: 0.8),
                        NmColors.background.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.4, 1],
                    ),
                  ),
                ),
              ),
            ),

            // ── Top bar: "walk in progress" + language + my places ─────────────────
            Positioned(
              top: topInset + 12,
              left: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Flexible(child: _walkPill()),
                      const SizedBox(width: 10),
                      const Spacer(),
                      _languageButton(),
                      const SizedBox(width: 10),
                      _myPlacesButton(),
                    ],
                  ),
                  // Something the user can act on (no connection, voice failed…).
                  if (guideStatus != null &&
                      guideStatus.tone == GuideTone.attention) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.topCenter,
                      child: _buildStatusPill(guideStatus),
                    ),
                  ],
                ],
              ),
            ),

            // ── Map buttons above the card + the card itself ───────────────────────
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
                    Padding(
                      padding: const EdgeInsets.only(right: 16, bottom: 12),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _mapButtons(),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.74,
                      ),
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.bottomCenter,
                        child: _bottomCard(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else
            // ── Start screen / "walk finished" (covers the map) ─────────────────────
            Positioned.fill(
              child: _c.status == WalkStatus.stopped
                  ? _walkFinishedView()
                  : _startView(),
            ),
        ],
      ),
    );
  }

  // ── Top bar pieces ────────────────────────────────────────────────────────────

  Widget _walkPill() {
    return Container(
      height: 44,
      padding: const EdgeInsets.fromLTRB(14, 0, 18, 0),
      decoration: BoxDecoration(
        color: NmColors.surface,
        borderRadius: BorderRadius.circular(999),
        boxShadow: nmShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const NmPulse(size: 10),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              L.t('Прогулянка триває', 'Walk in progress'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: NmColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Language (the interface, the stories, the AI and the voice follow it).
  Widget _languageButton() {
    return NmCircleButton(
      tooltip: L.t('Мова', 'Language'),
      onPressed: () => _showLanguageSheet(context, _c),
      child: Text(
        L.lang.code.toUpperCase(),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: NmColors.ink,
        ),
      ),
    );
  }

  /// Places already visited (always reachable, also while a place card is open).
  Widget _myPlacesButton() {
    final count = _c.visitedPlaces.length;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        NmCircleButton(
          tooltip: L.t('Мої місця', 'My places'),
          onPressed: () => _showVisitedSheet(context),
          child: const NmIcon(NmIcons.places, size: 22),
        ),
        if (count > 0)
          Positioned(
            right: -4,
            top: -4,
            child: IgnorePointer(
              child: Container(
                constraints: const BoxConstraints(minWidth: 20),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: NmColors.ink,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Text(
                  '$count',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Compass (turns the map north-up) and "show where I am".
  Widget _mapButtons() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        StreamBuilder<MapEvent>(
          stream: _mapController.mapEventStream,
          builder: (ctx, snap) {
            double rotation = 0.0;
            try {
              rotation = _mapController.camera.rotation;
            } catch (_) {}
            return NmCircleButton(
              size: 48,
              tooltip: L.t('Повернути мапу північчю вгору', 'Turn the map north up'),
              onPressed: () {
                try {
                  _mapController.rotate(0.0);
                } catch (_) {}
              },
              child: NmCompass(mapRotation: rotation),
            );
          },
        ),
        const SizedBox(height: 12),
        NmCircleButton(
          size: 48,
          tooltip: L.t('Показати, де я', 'Show where I am'),
          onPressed: _locateMe,
          child: NmIcon(
            NmIcons.locate,
            size: 22,
            color: _followUser ? NmColors.ink : NmColors.muted,
          ),
        ),
      ],
    );
  }

  // ── Bottom card ───────────────────────────────────────────────────────────────

  Widget _bottomCard() {
    final poi = _c.activePoi;
    final audio = _c.isAudioActive;

    if (poi != null && audio && _collapsed) return _miniPlayer(poi);

    final Widget content;
    if (poi == null) {
      content = audio ? _guideSpeakingContent() : _searchingContent();
    } else if (_c.isProcessing && !audio) {
      content = _preparingContent(poi);
    } else if (_c.isSilentPoi(poi.id) && !audio) {
      content = _silentContent(poi);
    } else {
      content = _placeContent(poi);
    }

    return Container(
      key: const ValueKey('nm-card'),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        color: NmColors.surface,
        borderRadius: BorderRadius.circular(32),
        boxShadow: nmShadow,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: content,
      ),
    );
  }

  /// Screen 2 — walking, nothing nearby yet.
  Widget _searchingContent() {
    final status = _c.guideStatus;
    final busyLine =
        (status != null && status.tone == GuideTone.busy) ? status.text : null;

    // The nearest place the user has not been to yet.
    String? nearestLine;
    final pos = _c.currentPosition;
    if (pos != null && _c.allPois.isNotEmpty) {
      Poi? nearest;
      double? best;
      for (final p in _c.allPois) {
        if (_c.visitedPoiIds.contains(p.id)) continue;
        final d = Geolocator.distanceBetween(
            pos.latitude, pos.longitude, p.latitude, p.longitude);
        if (best == null || d < best) {
          best = d;
          nearest = p;
        }
      }
      if (nearest != null && best != null) {
        nearestLine = L.t(
            'Найближче: ${nearest.shownName} · ${L.distance(best)}',
            'Nearest: ${nearest.shownName} · ${L.distance(best)}');
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            NmPulse(
              size: 52,
              child: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  color: NmColors.cream,
                  shape: BoxShape.circle,
                ),
                child: const Center(child: NmIcon(NmIcons.walk, size: 26)),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                L.t('Шукаємо цікаві місця поруч',
                    'Looking for interesting places nearby'),
                style: NmText.title(22),
              ),
            ),
            IconButton(
              tooltip: L.t('Оновити об\'єкти на карті', 'Refresh places on the map'),
              icon: const NmIcon(NmIcons.refresh, size: 20, color: NmColors.muted),
              onPressed: () => _c.reloadOsmPois(),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          L.t(
              'Гуляйте у своєму темпі. Щойно підійдете до цікавого місця — гід сам почне розповідь.',
              'Walk at your own pace. As soon as you get close to an interesting place, the guide starts the story.'),
          style: NmText.body.copyWith(color: NmColors.muted),
        ),
        if (busyLine != null) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(busyLine, style: NmText.small)),
            ],
          ),
        ] else if (nearestLine != null) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              const NmIcon(NmIcons.pin, size: 16, color: NmColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  nearestLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NmText.small,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        _endWalkButton(),
      ],
    );
  }

  /// Screen 3 — near a place, the story is being prepared (three steps).
  Widget _preparingContent(Poi poi) {
    final kind = poiKindOf(poi);
    final enriched = _c.getEnrichedPoi(poi.id);
    final updated = _c.getUpdatedPoi(poi);
    final hasStory = updated.narrationText.isNotEmpty ||
        (enriched?.narrationText?.isNotEmpty ?? false);
    final hasFacts = hasStory || (enriched?.isResearchComplete ?? false);
    final step = !hasFacts ? 0 : (!hasStory ? 1 : 2);

    final labels = <List<String>>[
      // pending, in progress, done
      [
        L.t('Шукаємо факти про місце', 'Looking for facts about the place'),
        L.t('Шукаємо факти про місце…', 'Looking for facts about the place…'),
        L.t('Знайшли факти про місце', 'Found facts about the place'),
      ],
      [
        L.t('ШІ пише розповідь', 'The AI writes the story'),
        L.t('ШІ пише розповідь…', 'The AI is writing the story…'),
        L.t('Розповідь готова', 'The story is ready'),
      ],
      [
        L.t('Готуємо озвучення', 'Preparing the voice'),
        L.t('Готуємо озвучення…', 'Preparing the voice…'),
        L.t('Озвучення готове', 'The voice is ready'),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Align(
                alignment: Alignment.centerLeft,
                child: NmBadge(
                  L.t('Ви поруч із цікавим місцем',
                      'You are near an interesting place'),
                  icon: NmIcons.pin,
                ),
              ),
            ),
            _reportButton(context, _c, poi),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            NmPlaceThumb(icon: kind.icon, size: 64),
            const SizedBox(width: 16),
            Expanded(
              child: Text(poi.shownName,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: NmText.title(22)),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Row(
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      Expanded(child: _progressSegment(i < step ? 1 : (i == step ? 0.45 : 0))),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _stepRow(
                  labels[i][i < step ? 2 : (i == step ? 1 : 0)],
                  done: i < step,
                  active: i == step,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          L.t(
              'Це займе кілька секунд — розповідь почнеться сама. Телефон можна сховати в кишеню.',
              'This takes a few seconds — the story starts by itself. You can put the phone in your pocket.'),
          style: NmText.small.copyWith(height: 18 / 13),
        ),
        const SizedBox(height: 20),
        _endWalkButton(),
      ],
    );
  }

  Widget _progressSegment(double filled) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: NmColors.cream)),
            FractionallySizedBox(
              widthFactor: filled,
              heightFactor: 1,
              child: const ColoredBox(color: NmColors.ink),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepRow(String text, {required bool done, required bool active}) {
    final Widget mark;
    if (done) {
      mark = Container(
        width: 24,
        height: 24,
        decoration: const BoxDecoration(color: NmColors.ink, shape: BoxShape.circle),
        child: const Center(child: NmIcon(NmIcons.check, size: 14, color: Colors.white)),
      );
    } else if (active) {
      mark = const SizedBox(
        width: 24,
        height: 24,
        child: Padding(
          padding: EdgeInsets.all(1),
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: NmColors.ink,
            backgroundColor: NmColors.cream,
          ),
        ),
      );
    } else {
      mark = SizedBox(
        width: 24,
        height: 24,
        child: Center(
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: NmColors.stepIdle, width: 2),
            ),
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 28),
      child: Row(
        children: [
          mark,
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 16,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: (done || active) ? NmColors.ink : NmColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A place shown on the map but with nothing verified to tell.
  Widget _silentContent(Poi poi) {
    final kind = poiKindOf(poi);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _placeHeader(poi, kind, trailing: _reportButton(context, _c, poi)),
        const SizedBox(height: 18),
        _silentNote(),
        const SizedBox(height: 18),
        _askAiButton(poi, primary: false),
        const SizedBox(height: 10),
        _endWalkButton(),
      ],
    );
  }

  /// Screen 4 — the story is playing (or ready to play).
  Widget _placeContent(Poi poi) {
    final kind = poiKindOf(poi);
    final playing = _c.isPlaying;
    final active = _c.isAudioActive;
    final displayText =
        poi.narrationText.isNotEmpty ? poi.narrationText : poi.shortDescription;
    final next = _c.nearestUnvisited(excluding: poi.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (active)
          Semantics(
            button: true,
            label: L.t('Згорнути картку', 'Collapse the card'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _collapsed = true),
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) > 0) setState(() => _collapsed = true);
              },
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Center(child: _handle()),
              ),
            ),
          ),
        _placeHeader(
          poi,
          kind,
          trailing: active
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    NmCircleButton(
                      tooltip: L.t('Ще раз', 'Play again'),
                      background: NmColors.cream,
                      shadow: false,
                      onPressed: () => _c.replayAudio(),
                      child: const NmIcon(NmIcons.replay, size: 20),
                    ),
                    const SizedBox(width: 8),
                    NmCircleButton(
                      tooltip: L.t('Згорнути картку', 'Collapse the card'),
                      background: NmColors.background,
                      shadow: false,
                      onPressed: () => setState(() => _collapsed = true),
                      child: const NmIcon(NmIcons.down, size: 22),
                    ),
                  ],
                )
              : _reportButton(context, _c, poi),
        ),
        const SizedBox(height: 18),
        if (displayText.isNotEmpty)
          Text(
            displayText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: NmText.body.copyWith(color: NmColors.muted),
          ),
        Row(
          children: [
            InkWell(
              onTap: () => _showPoiDetails(context, poi),
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 36),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      L.t('Читати повністю', 'Read all'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: NmColors.ink,
                      ),
                    ),
                    const SizedBox(width: 2),
                    const NmIcon(NmIcons.right, size: 18),
                  ],
                ),
              ),
            ),
            const Spacer(),
            if (active) _reportButton(context, _c, poi),
          ],
        ),
        if (active) ...[
          const SizedBox(height: 6),
          ExcludeSemantics(
            child: StreamBuilder<Duration>(
              stream: _c.audioPositionStream,
              builder: (context, _) {
                final total = _c.audioDuration;
                final at = _c.audioPosition;
                final progress = (total == null || total <= Duration.zero)
                    ? 0.0
                    : at.inMilliseconds / total.inMilliseconds;
                return NmWave(playing: playing, progress: progress);
              },
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => playing ? _c.pauseAudio() : _c.resumeAudio(),
                  icon: NmIcon(playing ? NmIcons.pause : NmIcons.play, size: 20),
                  label: Text(playing ? L.t('Пауза', 'Pause') : L.t('Продовжити', 'Resume')),
                  style: NmButtons.secondary(minHeight: 52),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Semantics(
                  label: L.t('Завершити розповідь про це місце',
                      'Finish the story about this place'),
                  child: ElevatedButton.icon(
                    onPressed: () => _c.skipNarration(),
                    icon: const NmIcon(NmIcons.stop, size: 20),
                    label: Text(L.t('Завершити', 'Finish')),
                    style: NmButtons.secondary(minHeight: 52),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _askAiButton(poi, primary: true),
        ] else ...[
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                flex: 10,
                child: ElevatedButton.icon(
                  onPressed: () => _c.playNarrationForPoi(poi),
                  icon: const NmIcon(NmIcons.play, size: 20),
                  label: Text(L.t('Прослухати', 'Listen')),
                  style: NmButtons.secondary(minHeight: 52),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(flex: 13, child: _askAiButton(poi, primary: true)),
            ],
          ),
        ],
        if (next != null) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              const NmIcon(NmIcons.pin, size: 16, color: NmColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  L.t('Далі: ${next.poi.shownName} · ${L.distance(next.meters)}',
                      'Next: ${next.poi.shownName} · ${L.distance(next.meters)}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NmText.small,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        _endWalkButton(),
      ],
    );
  }

  /// Playing, but nothing on the map is selected (e.g. an AI answer read aloud).
  Widget _guideSpeakingContent() {
    final playing = _c.isPlaying;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          playing
              ? L.t('Гід розповідає', 'The guide is speaking')
              : L.t('Розповідь на паузі', 'The story is paused'),
          style: NmText.title(22),
        ),
        const SizedBox(height: 14),
        ExcludeSemantics(child: NmWave(playing: playing)),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => playing ? _c.pauseAudio() : _c.resumeAudio(),
                icon: NmIcon(playing ? NmIcons.pause : NmIcons.play, size: 20),
                label: Text(playing ? L.t('Пауза', 'Pause') : L.t('Продовжити', 'Resume')),
                style: NmButtons.secondary(minHeight: 52),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _c.stopAudio(),
                icon: const NmIcon(NmIcons.stop, size: 20),
                label: Text(L.t('Зупинити', 'Stop')),
                style: NmButtons.secondary(minHeight: 52),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _endWalkButton(),
      ],
    );
  }

  /// Screen 4б — the card folded into one row over the map.
  Widget _miniPlayer(Poi poi) {
    final kind = poiKindOf(poi);
    final playing = _c.isPlaying;
    void expand() => setState(() => _collapsed = false);

    return Container(
      key: const ValueKey('nm-mini'),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: NmColors.surface,
        borderRadius: BorderRadius.circular(28),
        boxShadow: nmShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: expand,
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < 0) expand();
            },
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Center(child: _handle()),
            ),
          ),
          Row(
            children: [
              NmPlaceThumb(icon: kind.icon, size: 52, radius: 16),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  button: true,
                  label: L.t('Розгорнути картку', 'Expand the card'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: expand,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          poi.shownName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NmText.title(18),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            ExcludeSemantics(
                              child: NmWave(
                                playing: playing,
                                bars: 3,
                                height: 12,
                                color: NmColors.ochre,
                                restColor: NmColors.ochre,
                                spread: false,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                playing
                                    ? L.t('Гід розповідає', 'The guide is speaking')
                                    : L.t('На паузі', 'Paused'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NmText.small,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              NmCircleButton(
                size: 48,
                tooltip: playing ? L.t('Пауза', 'Pause') : L.t('Продовжити', 'Resume'),
                background: NmColors.cream,
                shadow: false,
                onPressed: () => playing ? _c.pauseAudio() : _c.resumeAudio(),
                child: NmIcon(playing ? NmIcons.pause : NmIcons.play, size: 20),
              ),
              const SizedBox(width: 8),
              NmCircleButton(
                tooltip: L.t('Розгорнути картку', 'Expand the card'),
                background: NmColors.background,
                shadow: false,
                onPressed: expand,
                child: const NmIcon(NmIcons.up, size: 22),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _handle() => Container(
        width: 40,
        height: 5,
        decoration: BoxDecoration(
          color: NmColors.sand,
          borderRadius: BorderRadius.circular(3),
        ),
      );

  /// Photo tile · kind badge · name · (buttons on the right).
  Widget _placeHeader(Poi poi, PoiKind kind, {Widget? trailing}) {
    return Row(
      children: [
        NmPlaceThumb(icon: kind.icon),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NmBadge(kind.label, materialIcon: kind.icon),
              const SizedBox(height: 6),
              Text(
                poi.shownName,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: NmText.title(22),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing],
      ],
    );
  }

  Widget _askAiButton(Poi poi, {required bool primary}) {
    return ElevatedButton.icon(
      onPressed: () => _showAiChatSheet(context, poi),
      icon: NmIcon(NmIcons.ai,
          size: 20, color: primary ? Colors.white : NmColors.ink),
      label: Text(L.t('Запитати ШІ', 'Ask the AI')),
      style: primary
          ? NmButtons.primary(minHeight: 52)
          : NmButtons.secondary(minHeight: 52),
    );
  }

  Widget _endWalkButton() => NmEndWalkButton(
        label: L.t('Завершити прогулянку', 'End the walk'),
        onPressed: _confirmEndWalk,
      );

  /// Screen 7 — "Завершити прогулянку?" before the walk is really stopped.
  Future<void> _confirmEndWalk() async {
    _c.trackUi('end_walk_asked');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: NmColors.ink.withValues(alpha: 0.45),
      builder: (ctx) => SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          decoration: BoxDecoration(
            color: NmColors.surface,
            borderRadius: BorderRadius.circular(32),
            boxShadow: nmShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    color: NmColors.wineSoft,
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: NmIcon(NmIcons.flag, size: 26, color: NmColors.wine),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                L.t('Завершити прогулянку?', 'End the walk?'),
                textAlign: TextAlign.center,
                style: NmText.title(24),
              ),
              const SizedBox(height: 8),
              Text(
                L.t(
                    'Ми перестанемо відстежувати вашу геолокацію, а аудіогід вимкнеться. Нову прогулянку можна почати будь-коли.',
                    'We will stop tracking your location and the audio guide will switch off. You can start a new walk any time.'),
                textAlign: TextAlign.center,
                style: NmText.body.copyWith(color: NmColors.muted),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: NmButtons.destructive(),
                child: Text(L.t('Так, завершити', 'Yes, end it')),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                style: NmButtons.secondary().copyWith(
                  backgroundColor: const WidgetStatePropertyAll(NmColors.surface),
                  side: const WidgetStatePropertyAll(
                      BorderSide(color: NmColors.line, width: 1.5)),
                ),
                child: Text(L.t('Гуляти далі', 'Keep walking')),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true && mounted) {
      _c.stopWalk();
      setState(() => _collapsed = false);
    }
  }

  // ── Start screen (first open) ─────────────────────────────────────────────────

  Widget _startView() {
    // Location was refused: the main button becomes the way out (Allow / Settings).
    final status = _c.guideStatus;
    final denied = status != null && status.hasAction;
    final height = MediaQuery.of(context).size.height;
    final heroHeight = math.min(500.0, height * 0.56);

    return ColoredBox(
      color: NmColors.background,
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: IntrinsicHeight(
              child: Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: heroHeight,
                    child: Image.asset(
                      'assets/images/hero_start.png',
                      fit: BoxFit.cover,
                      alignment: Alignment.bottomCenter,
                      excludeFromSemantics: true,
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: Row(
                            children: [
                              const SizedBox(width: 44),
                              const Spacer(),
                              _logoPill(),
                              const Spacer(),
                              _languageButton(),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: math.max(0.0, heroHeight - 30 - 56 - MediaQuery.of(context).padding.top)),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                              24, 0, 24, 24 + MediaQuery.of(context).padding.bottom),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                L.t('Гуляйте — історії місць знайдуть вас самі',
                                    'Walk — the stories of places will find you'),
                                textAlign: TextAlign.center,
                                style: NmText.title(30).copyWith(height: 38 / 30),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                L.t(
                                    'Аудіогід сам почне розповідь, щойно ви підійдете до цікавого місця. Нічого не треба шукати.',
                                    'The audio guide starts a story as soon as you come close to an interesting place. Nothing to look for.'),
                                textAlign: TextAlign.center,
                                style: NmText.body.copyWith(color: NmColors.muted),
                              ),
                              const SizedBox(height: 16),
                              _stepsLine(),
                              const Spacer(),
                              const SizedBox(height: 24),
                              SizedBox(
                                height: 60,
                                child: ElevatedButton(
                                  onPressed: denied
                                      ? () => _c.runStatusAction()
                                      : () => _c.startWalk(),
                                  style: NmButtons.primary(minHeight: 60),
                                  child: Text(denied
                                      ? (status.actionLabel ?? '')
                                      : L.t('Почати прогулянку', 'Start the walk')),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                denied
                                    ? status.text
                                    : L.t('Потрібна геолокація · краще в навушниках',
                                        'Location is needed · best with headphones'),
                                textAlign: TextAlign.center,
                                style: NmText.small,
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
        ),
      ),
    );
  }

  Widget _logoPill() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(999),
        boxShadow: nmShadow,
      ),
      alignment: Alignment.center,
      child: Text('NotMiss', style: NmText.title(20)),
    );
  }

  /// «Гуляйте · Підходьте · Слухайте»
  Widget _stepsLine() {
    Widget item(NmIcons icon, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NmIcon(icon, size: 16),
            const SizedBox(width: 6),
            Text(text, style: NmText.small),
          ],
        );
    Widget dot() => Container(
          width: 3,
          height: 3,
          margin: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            color: NmColors.stone,
            shape: BoxShape.circle,
          ),
        );
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 6,
      children: [
        item(NmIcons.walk, L.t('Гуляйте', 'Walk')),
        dot(),
        item(NmIcons.pin, L.t('Підходьте', 'Come close')),
        dot(),
        item(NmIcons.headphones, L.t('Слухайте', 'Listen')),
      ],
    );
  }

  // ── Walk finished (screen 8) ──────────────────────────────────────────────────

  Widget _walkFinishedView() {
    final heard = _c.walkListenedPlaces;
    final n = heard.length;
    final height = MediaQuery.of(context).size.height;
    final heroHeight = math.min(330.0, height * 0.36);
    const rowHeight = 44.0;
    const visibleRows = 5;
    final more = n - visibleRows;

    final caption = L.en
        ? (n == 1 ? '1 story' : '$n stories')
        : '$n ${ukPlural(n, 'історія', 'історії', 'історій')}';

    return ColoredBox(
      color: NmColors.background,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: heroHeight,
            child: Image.asset(
              'assets/images/hero_after.png',
              fit: BoxFit.cover,
              alignment: Alignment.bottomCenter,
              excludeFromSemantics: true,
            ),
          ),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _languageButton(),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                        12, math.max(0.0, heroHeight - 68 - 56 - MediaQuery.of(context).padding.top), 12, 12),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                      decoration: BoxDecoration(
                        color: NmColors.surface,
                        borderRadius: BorderRadius.circular(32),
                        boxShadow: nmShadow,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            caption,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: NmColors.muted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(L.t('Прогулянку завершено', 'Walk finished'),
                              style: NmText.title(26)),
                          const SizedBox(height: 14),
                          if (n == 0)
                            Text(
                              L.t(
                                  'Цього разу історій не було. Наступного разу підходьте ближче до цікавих місць на мапі.',
                                  'No stories this time. Next time, walk closer to the interesting places on the map.'),
                              style: NmText.body.copyWith(color: NmColors.muted),
                            )
                          else
                            SizedBox(
                              height: math.min(n, visibleRows) * rowHeight + 8,
                              child: Stack(
                                children: [
                                  Semantics(
                                    label: L.t('Почуті місця, від останнього',
                                        'Places heard, most recent first'),
                                    child: ListView.builder(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      itemCount: n,
                                      itemExtent: rowHeight,
                                      itemBuilder: (ctx, i) => _heardRow(heard[i]),
                                    ),
                                  ),
                                  if (more > 0)
                                    const Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      height: 44,
                                      child: IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [Color(0x00FFFFFF), Colors.white],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (more > 0) ...[
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const NmIcon(NmIcons.down, size: 16, color: NmColors.muted),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    L.en
                                        ? '$more more ${more == 1 ? 'place' : 'places'} — scroll the list'
                                        : 'Ще $more ${ukPlural(more, 'місце', 'місця', 'місць')} — прогорніть список',
                                    style: NmText.small,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (_c.visitedPlaces.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Center(
                              child: TextButton(
                                onPressed: () => _showVisitedSheet(context),
                                child: Text(L.t('Усі мої місця · ${_c.visitedPlaces.length}',
                                    'All my places · ${_c.visitedPlaces.length}')),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        L.t('Геолокацію вимкнено, гід мовчить',
                            'Location is off, the guide is quiet'),
                        textAlign: TextAlign.center,
                        style: NmText.small,
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 60,
                        child: ElevatedButton(
                          onPressed: () => _c.startWalk(),
                          style: NmButtons.primary(minHeight: 60),
                          child: Text(L.t('Почати прогулянку', 'Start the walk')),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _heardRow(VisitedPlace place) {
    Poi? poi;
    for (final p in _c.allPois) {
      if (p.id == place.id) {
        poi = p;
        break;
      }
    }
    final name = place.name.isEmpty ? L.t('Місце', 'Place') : PlaceNames.of(place.name, null);
    return InkWell(
      onTap: poi == null ? null : () => _showPoiDetails(context, poi!),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(color: NmColors.cream, shape: BoxShape.circle),
            child: const Center(child: NmIcon(NmIcons.check, size: 14)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, height: 20 / 16, color: NmColors.ink),
            ),
          ),
        ],
      ),
    );
  }

  // ── Sheets and screens opened from the map ────────────────────────────────────

  void _showVisitedSheet(BuildContext context) {
    widget.controller.trackUi('my_places_opened');
    var tab = 0; // 0 = listened, 1 = passed but not listened
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => ListenableBuilder(
          listenable: widget.controller,
          builder: (ctx, _) {
            final listened = widget.controller.listenedPlaces;
            final passed = widget.controller.passedOnlyPlaces;
            final places = tab == 0 ? listened : passed;
            return Material(
              color: Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.75),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 12),
                      Center(
                        child: Container(
                          width: 44,
                          height: 4,
                          decoration: BoxDecoration(
                            color: NmColors.sand,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                        child: Text(L.t('Мої місця', 'My places'),
                            style: NmText.title(22)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            ChoiceChip(
                              avatar: const Icon(Icons.headphones, size: 16),
                              label: Text(L.t('Прослухані · ${listened.length}',
                                  'Listened · ${listened.length}')),
                              selected: tab == 0,
                              onSelected: (_) => setSheet(() => tab = 0),
                            ),
                            ChoiceChip(
                              avatar:
                                  const Icon(Icons.directions_walk, size: 16),
                              label: Text(L.t('Пройдені · ${passed.length}',
                                  'Passed · ${passed.length}')),
                              selected: tab == 1,
                              onSelected: (_) => setSheet(() => tab = 1),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                        child: Text(
                          tab == 0
                              ? L.t('Розповідь прослухано до кінця.',
                                  'The story was heard to the end.')
                              : L.t(
                                  'Ви були поруч, але розповідь не прослухали — натисніть, щоб послухати.',
                                  'You were nearby but did not hear the story — tap to listen.'),
                          style: const TextStyle(
                              fontSize: 12, color: NmColors.muted),
                        ),
                      ),
                      if (places.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                          child: Text(
                            tab == 0
                                ? L.t(
                                    'Поки що порожньо — місця з\'являться тут, коли ви дослухаєте розповідь.',
                                    'Nothing yet — places appear here once you hear a story to the end.')
                                : L.t('Поки що порожньо.', 'Nothing yet.'),
                            style: const TextStyle(
                                fontSize: 15, color: NmColors.muted),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            itemCount: places.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 4),
                            itemBuilder: (ctx, i) {
                              final place = places[i];
                              final kind =
                                  PoiKind.values.asNameMap()[place.kind] ??
                                      PoiKind.other;
                              Poi? poi;
                              for (final p in widget.controller.allPois) {
                                if (p.id == place.id) {
                                  poi = p;
                                  break;
                                }
                              }
                              return ListTile(
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: const BoxDecoration(
                                    color: NmColors.cream,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(kind.icon,
                                      size: 22, color: NmColors.ink),
                                ),
                                title: Text(
                                  place.name.isEmpty
                                      ? L.t('Місце', 'Place')
                                      : PlaceNames.of(place.name, null),
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(kind.label,
                                    style: const TextStyle(
                                        fontSize: 12, color: NmColors.muted)),
                                trailing: Icon(
                                  place.listened
                                      ? Icons.headphones
                                      : Icons.directions_walk,
                                  size: 18,
                                  color: NmColors.stone,
                                ),
                                onTap: poi == null
                                    ? null
                                    : () {
                                        Navigator.of(ctx).pop();
                                        _showPoiDetails(context, poi!);
                                      },
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildStatusPill(GuideStatus status) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 6, status.hasAction ? 6 : 16, 6),
      decoration: BoxDecoration(
        color: NmColors.surface,
        borderRadius: BorderRadius.circular(999),
        boxShadow: nmShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status.tone == GuideTone.busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: NmColors.ink),
            )
          else
            const Icon(Icons.info_outline, size: 18, color: NmColors.ink),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              status.text,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: NmColors.ink,
              ),
            ),
          ),
          if (status.hasAction) ...[
            const SizedBox(width: 6),
            TextButton(
              onPressed: () => widget.controller.runStatusAction(),
              child: Text(
                status.actionLabel!,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showAiChatSheet(BuildContext context, Poi poi) {
    widget.controller.trackUi('chat_opened', poi);
    _showAiChatModal(context, widget.controller, poi);
  }

  Marker _buildPoiMarker(Poi poi,
      {required bool isActive,
      required bool isTriggered,
      required bool isListened,
      required bool isSilent}) {
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
            _mapController.move(LatLng(poi.latitude, poi.longitude),
                _mapController.camera.zoom);
          } catch (_) {}
          _showPoiDetails(context, poi);
        },
        child: Center(
          child: Tooltip(
            message:
                '${poiKindOf(poi).label}: ${poi.shownName}${isSilent ? L.t(' — не озвучується (немає джерел)', ' — not narrated (no sources)') : ''}${isTriggered ? (isListened ? L.t(' — прослухано', ' — listened') : L.t(' — пройдено', ' — passed')) : ''}',
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
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  Icon(poiKindOf(poi).icon, color: Colors.white, size: 19),
                  if ((isTriggered || isSilent) && !isActive)
                    Positioned(
                      right: -5,
                      bottom: -5,
                      child: Container(
                        width: 15,
                        height: 15,
                        decoration: BoxDecoration(
                          // Headphones: the story was heard. Walking figure: passed, not heard.
                          color: isSilent
                              ? NmColors.wine
                              : (isListened ? NmColors.ink : NmColors.muted),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: Icon(
                            isSilent
                                ? Icons.volume_off
                                : (isListened
                                    ? Icons.headphones
                                    : Icons.directions_walk),
                            color: Colors.white,
                            size: 10),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showPoiDetails(BuildContext context, Poi poi) {
    widget.controller.trackUi('details_opened', poi);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => _PoiDetailsSheet(
        controller: widget.controller,
        poi: poi,
      ),
    ));
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

/// Screen 5 — everything about one place: photo, story, facts, sources.
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

    final hasNarration = (enriched?.narrationText?.isNotEmpty == true ||
        updatedPoi.narrationText.isNotEmpty);
    final rawDesc = (enriched?.shortDescription?.isNotEmpty == true)
        ? enriched!.shortDescription!
        : updatedPoi.shortDescription;
    final hasRichDesc = !PoiCategoryService.isTrivialDescription(rawDesc);
    final hasFacts =
        (enriched?.keyFacts.isNotEmpty == true || updatedPoi.facts.isNotEmpty);

    final hasFallback = enriched?.hasFallbackContent ?? false;
    final hasCompleteData =
        hasNarration && hasRichDesc && hasFacts && !hasFallback;

    if ((!hasCompleteData || hasFallback) && !_isRequesting) {
      _isRequesting = true;
      widget.controller
          .researchPoiNow(widget.poi, force: hasFallback)
          .whenComplete(() {
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
        final c = widget.controller;
        final enriched = c.getEnrichedPoi(widget.poi.id);
        final updatedPoi = c.getUpdatedPoi(widget.poi);
        final queuePos = c.getQueuePosition(widget.poi.id);

        // Stored texts from older versions may still carry a greeting or be too long.
        final narration = TextQuality.finalizeNarration(
            (enriched?.narrationText?.isNotEmpty == true)
                ? enriched!.narrationText!
                : updatedPoi.narrationText);

        final rawDesc = (enriched?.shortDescription?.isNotEmpty == true)
            ? enriched!.shortDescription!
            : updatedPoi.shortDescription;
        final description =
            PoiCategoryService.isTrivialDescription(rawDesc) ? '' : rawDesc;

        final facts = (enriched?.keyFacts.isNotEmpty == true)
            ? enriched!.keyFacts.map((f) => f.fact).toList()
            : updatedPoi.facts;

        final isThis = c.activePoi?.id == widget.poi.id;
        final isPlayingThisPoi = c.isPlaying && isThis;
        final isAudioActiveThisPoi = c.isAudioActive && isThis;
        final preparingThis = c.isProcessing && isThis;
        final silent = c.isSilentPoi(widget.poi.id);

        final isProcessing = _isRequesting ||
            queuePos == 0 ||
            (enriched != null &&
                enriched.researchStatus == ResearchStatus.inProgress);

        final kind = poiKindOf(widget.poi);
        // What the text rests on: the user can see where it comes from.
        final sourceTitles = (enriched?.sources ?? const <ResearchSource>[])
            .where((s) => s.type != 'ai')
            .map((s) => s.title)
            .toSet()
            .toList();

        // Under the name: what it is, and how far away.
        String subtitle = kind.label;
        final pos = c.currentPosition;
        if (pos != null && c.status == WalkStatus.walking) {
          final d = Geolocator.distanceBetween(pos.latitude, pos.longitude,
              widget.poi.latitude, widget.poi.longitude);
          subtitle = '$subtitle · ${L.distance(d)}';
        }

        // The story leads; the description follows only when it says something else.
        final lead = narration.isNotEmpty ? narration : description;
        final showDescription =
            narration.isNotEmpty && description.isNotEmpty && description != narration;

        final textStyle = NmText.body;

        final topInset = MediaQuery.of(context).padding.top;
        final screenH = MediaQuery.of(context).size.height;
        final photoH = math.min(330.0, screenH * 0.36);

        return Scaffold(
          backgroundColor: NmColors.background,
          body: Stack(
            children: [
              // Photo area (the real photo of the place comes in step 4).
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: photoH,
                child: ColoredBox(
                  color: NmColors.cream,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: topInset * 0.5, bottom: 34),
                      child: Icon(kind.icon, size: 64, color: NmColors.stone),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: topInset + 12,
                left: 16,
                child: NmCircleButton(
                  tooltip: L.t('Назад до мапи', 'Back to the map'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const NmIcon(NmIcons.back, size: 22),
                ),
              ),
              // The white sheet with the text.
              Positioned.fill(
                top: photoH - 34,
                child: Container(
                  decoration: const BoxDecoration(
                    color: NmColors.surface,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.poi.shownName,
                                  style: NmText.title(28).copyWith(height: 35 / 28)),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const NmIcon(NmIcons.pin, size: 15, color: NmColors.muted),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(subtitle, style: NmText.small)),
                                ],
                              ),
                              const SizedBox(height: 18),

                              // Still gathering information
                              if (isProcessing &&
                                  (narration.isEmpty || description.isEmpty)) ...[
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: NmColors.background,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    children: [
                                      const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                          backgroundColor: NmColors.cream,
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              queuePos > 0
                                                  ? L.t(
                                                      'Об\'єкт у черзі на дослідження (позиція: $queuePos)…',
                                                      'The place is queued for research (position: $queuePos)…')
                                                  : L.t(
                                                      'Шукаємо інформацію про це місце (Вікіпедія, Вікідані)…',
                                                      'Looking for information about this place (Wikipedia, Wikidata)…'),
                                              style: const TextStyle(
                                                fontSize: 15,
                                                color: NmColors.ink,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              L.t('Зачекайте 1-2 секунди, інформація завантажується автоматично.',
                                                  'Wait a second or two, the information is loading automatically.'),
                                              style: NmText.small,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],

                              if (silent) ...[
                                _silentNote(),
                                const SizedBox(height: 16),
                              ],

                              // The story itself (the spoken word lights up while it plays).
                              if (lead.isNotEmpty) ...[
                                if (lead == narration)
                                  SpokenText(
                                    text: narration,
                                    // Only while this place's story (not the chime) is playing.
                                    active: isAudioActiveThisPoi && c.isNarrationLoaded,
                                    position: c.audioPositionStream,
                                    currentPosition: () => c.audioPosition,
                                    duration: () => c.audioDuration,
                                    style: textStyle,
                                  )
                                else
                                  Text(lead, style: textStyle),
                                const SizedBox(height: 16),
                              ],

                              if (showDescription) ...[
                                Text(L.t('Про місце', 'About the place'),
                                    style: NmText.title(18)),
                                const SizedBox(height: 10),
                                Text(description, style: textStyle),
                                const SizedBox(height: 16),
                              ],

                              if (facts.isNotEmpty) ...[
                                Text(L.t('Цікаві факти', 'Interesting facts'),
                                    style: NmText.title(18)),
                                const SizedBox(height: 10),
                                for (final f in facts)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          width: 6,
                                          height: 6,
                                          margin: const EdgeInsets.only(top: 9),
                                          decoration: const BoxDecoration(
                                            color: NmColors.ochre,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(child: Text(f, style: textStyle)),
                                      ],
                                    ),
                                  ),
                                const SizedBox(height: 8),
                              ],

                              if (sourceTitles.isNotEmpty) ...[
                                Text(
                                  L.t('Джерела: ${sourceTitles.join(' · ')}',
                                      'Sources: ${sourceTitles.join(' · ')}'),
                                  style: NmText.small,
                                ),
                                const SizedBox(height: 12),
                              ],

                              // Nothing at all yet: offer to prepare it.
                              if (!isProcessing &&
                                  !silent &&
                                  narration.isEmpty &&
                                  description.isEmpty &&
                                  facts.isEmpty) ...[
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: NmColors.background,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        L.t('Цей об\'єкт знайдено на карті',
                                            'This place was found on the map'),
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: NmColors.ink,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        L.t('У відкритих реєстрах стаття відсутня, проте ШІ може підготувати опис та розповідь прямо зараз.',
                                            'There is no article in open registers, but the AI can prepare a description and story right now.'),
                                        style: NmText.small,
                                      ),
                                      const SizedBox(height: 12),
                                      OutlinedButton(
                                        onPressed: () {
                                          setState(() => _isRequesting = true);
                                          c
                                              .researchPoiNow(widget.poi, force: true)
                                              .whenComplete(() {
                                            if (mounted) {
                                              setState(() => _isRequesting = false);
                                            }
                                          });
                                        },
                                        style: NmButtons.secondary(minHeight: 48),
                                        child: Text(L.t('Згенерувати опис ШІ зараз',
                                            'Generate the AI description now')),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],

                              Align(
                                alignment: Alignment.centerLeft,
                                child: _reportTextButton(context, c, widget.poi),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // «Прослухати» · «Запитати ШІ»
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
                          child: Row(
                            children: [
                              if (!silent) ...[
                                Expanded(
                                  flex: 10,
                                  child: Semantics(
                                    label: isAudioActiveThisPoi
                                        ? null
                                        : L.t('Прослухати розповідь знову',
                                            'Listen to the story again'),
                                    child: ElevatedButton(
                                      onPressed: preparingThis
                                          ? null
                                          : () {
                                              if (isPlayingThisPoi) {
                                                c.pauseAudio();
                                              } else if (isAudioActiveThisPoi) {
                                                c.resumeAudio();
                                              } else {
                                                c.playNarrationForPoi(widget.poi);
                                              }
                                            },
                                      style: NmButtons.secondary(),
                                      child: Text(
                                        preparingThis
                                            ? L.t('Готуємо…', 'Preparing…')
                                            : isPlayingThisPoi
                                                ? L.t('Пауза', 'Pause')
                                                : isAudioActiveThisPoi
                                                    ? L.t('Продовжити', 'Resume')
                                                    : L.t('Прослухати', 'Listen'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                              ],
                              Expanded(
                                flex: 13,
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    c.trackUi('chat_opened', widget.poi);
                                    _showAiChatModal(context, c, widget.poi);
                                  },
                                  icon: const NmIcon(NmIcons.ai, size: 20, color: Colors.white),
                                  label: Text(
                                    L.t('Запитати ШІ', 'Ask the AI'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  style: NmButtons.primary(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Opens the full-screen chat with the guide about [poi].
void _showAiChatModal(
    BuildContext context, WalkController controller, Poi poi) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (context) => _AiChatSheet(
      controller: controller,
      poi: poi,
    ),
  ));
}

/// Screen 6 — ask the guide (Gemini) about a place.
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
  List<ChatMessage> get _messages =>
      widget.controller.getChatHistory(widget.poi.id);
  bool _isLoading = false;
  String? _currentlySpeakingText;

  List<String> get _quickQuestions => [
        L.t('Коли це з\'явилося?', 'When was it built?'),
        L.t('Чим особливе це місце?', 'What is special about this place?'),
        L.t('Хто автор чи архітектор?', 'Who is the author or architect?'),
        L.t('Розкажи цікавий факт', 'Tell me an interesting fact'),
        L.t('Яка тут історія чи легенда?',
            'What is the history or legend here?'),
      ];

  @override
  void initState() {
    super.initState();
    final history = widget.controller.getChatHistory(widget.poi.id);
    if (history.isEmpty) {
      widget.controller.addChatMessage(
        widget.poi.id,
        ChatMessage(
          text: L.t(
              'Запитайте мене про «${widget.poi.shownName}»: його історію, людей і події, пов\'язані з ним. '
                  'Відповідаю лише за перевіреними джерелами.',
              'Ask me about "${widget.poi.shownName}": its history and the people and events connected with it. '
                  'I answer only from verified sources.'),
          isUser: false,
        ),
      );
    }
    _scrollToBottom();
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
          text: L.t('Вибачте, виникла помилка зв\'язку з ШІ: $e',
              'Sorry, there was a connection error with the AI: $e'),
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
    return Scaffold(
      backgroundColor: NmColors.surface,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            // Header: back · «Запитайте гіда» / «Про …» · AI mark
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                children: [
                  NmCircleButton(
                    tooltip: L.t('Назад', 'Back'),
                    background: NmColors.background,
                    shadow: false,
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const NmIcon(NmIcons.back, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(L.t('Запитайте гіда', 'Ask the guide'),
                            style: NmText.title(20)),
                        const SizedBox(height: 2),
                        Text(
                          L.t('Про «${widget.poi.shownName}»',
                              'About "${widget.poi.shownName}"'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NmText.small,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: NmColors.cream,
                      shape: BoxShape.circle,
                    ),
                    child: const Center(child: NmIcon(NmIcons.ai, size: 22)),
                  ),
                ],
              ),
            ),

            // Messages
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
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

            // Quick questions
            SizedBox(
              height: 56,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                scrollDirection: Axis.horizontal,
                itemCount: _quickQuestions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final q = _quickQuestions[index];
                  return OutlinedButton(
                    onPressed: _isLoading ? null : () => _sendMessage(q),
                    style: ButtonStyle(
                      backgroundColor:
                          const WidgetStatePropertyAll(NmColors.surface),
                      foregroundColor: WidgetStateProperty.resolveWith((s) =>
                          s.contains(WidgetState.disabled)
                              ? NmColors.stone
                              : NmColors.ink),
                      side: const WidgetStatePropertyAll(
                          BorderSide(color: NmColors.line)),
                      shape: const WidgetStatePropertyAll(StadiumBorder()),
                      minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
                      padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 16)),
                      textStyle: const WidgetStatePropertyAll(TextStyle(
                        fontFamily: NmFonts.sans,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      )),
                    ),
                    child: Text(q),
                  );
                },
              ),
            ),

            // Input
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _sendMessage,
                      style: NmText.body,
                      decoration: InputDecoration(
                        hintText: L.t('Запитайте про це місце…',
                            'Ask about this place…'),
                        // 52 px tall pill, as in the design.
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  NmCircleButton(
                    size: 52,
                    tooltip: L.t('Надіслати', 'Send'),
                    background: _isLoading ? NmColors.stone : NmColors.ink,
                    shadow: false,
                    onPressed: _isLoading
                        ? null
                        : () => _sendMessage(_textController.text),
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const NmIcon(NmIcons.send,
                            size: 22, color: Colors.white),
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
    final width = MediaQuery.of(context).size.width;
    if (msg.isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: BoxConstraints(maxWidth: width * 0.78),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: NmColors.ink,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(22),
                topRight: Radius.circular(22),
                bottomLeft: Radius.circular(22),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Text(
              msg.text,
              style: NmText.body.copyWith(color: Colors.white),
            ),
          ),
        ),
      );
    }

    final isSpeaking = _currentlySpeakingText == msg.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width * 0.86),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  color: NmColors.background,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(22),
                    topRight: Radius.circular(22),
                    bottomRight: Radius.circular(22),
                    bottomLeft: Radius.circular(6),
                  ),
                ),
                child: Text(msg.text, style: NmText.body),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 36,
                child: OutlinedButton.icon(
                  onPressed: () => _speakMessage(msg.text),
                  icon: NmIcon(
                    isSpeaking ? NmIcons.stop : NmIcons.volume,
                    size: 15,
                    color: isSpeaking ? Colors.white : NmColors.ink,
                  ),
                  label: Text(isSpeaking
                      ? L.t('Зупинити', 'Stop')
                      : L.t('Озвучити', 'Read aloud')),
                  style: ButtonStyle(
                    backgroundColor: WidgetStatePropertyAll(
                        isSpeaking ? NmColors.ink : NmColors.surface),
                    foregroundColor: WidgetStatePropertyAll(
                        isSpeaking ? Colors.white : NmColors.ink),
                    side: WidgetStatePropertyAll(isSpeaking
                        ? BorderSide.none
                        : const BorderSide(color: NmColors.line)),
                    shape: const WidgetStatePropertyAll(StadiumBorder()),
                    minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
                    padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 14)),
                    textStyle: const WidgetStatePropertyAll(TextStyle(
                      fontFamily: NmFonts.sans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    )),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingBubble() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: NmColors.background,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(22),
              topRight: Radius.circular(22),
              bottomRight: Radius.circular(22),
              bottomLeft: Radius.circular(6),
            ),
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
                L.t('Гід думає над відповіддю…', 'The guide is thinking…'),
                style: NmText.small,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "This place is on the map but has no verified story, so it is not narrated."
Widget _silentNote() {
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: NmColors.cream,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.volume_off, size: 20, color: NmColors.wine),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            L.t(
              'Цей об\'єкт не озвучується: про нього немає перевірених джерел. Його видно лише на мапі.',
              'This place is not narrated: there are no verified sources about it. It is shown on the map only.',
            ),
            style: const TextStyle(
                fontSize: 14, color: NmColors.ink, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

/// Compact flag on a card: "inaccurate information".
Widget _reportButton(BuildContext context, WalkController controller, Poi poi) {
  final reported = controller.reportedPoiIds.contains(poi.id);
  return IconButton(
    tooltip: reported
        ? L.t('Ви вже повідомили про неточність', 'You already reported this')
        : L.t('Неточна інформація', 'Inaccurate information'),
    onPressed: () => _showReportSheet(context, controller, poi),
    icon: Icon(
      reported ? Icons.report : Icons.report_gmailerrorred_outlined,
      color: reported ? NmColors.wine : NmColors.muted,
    ),
  );
}

Widget _reportTextButton(
    BuildContext context, WalkController controller, Poi poi) {
  final reported = controller.reportedPoiIds.contains(poi.id);
  return TextButton.icon(
    onPressed: () => _showReportSheet(context, controller, poi),
    icon: Icon(
      reported ? Icons.report : Icons.report_gmailerrorred_outlined,
      size: 20,
      color: reported ? NmColors.wine : NmColors.muted,
    ),
    label: Text(
      reported
          ? L.t('Ви повідомили про неточність', 'You reported this')
          : L.t('Неточна інформація', 'Inaccurate information'),
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: reported ? NmColors.wine : NmColors.muted,
      ),
    ),
  );
}

void _showLanguageSheet(BuildContext context, WalkController controller) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => ListenableBuilder(
      listenable: controller,
      builder: (ctx, _) => Material(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Мова / Language', style: NmText.title(22)),
                const SizedBox(height: 6),
                Text(
                  L.t(
                    'Мова інтерфейсу, розповідей, відповідей ШІ та голосу гіда.',
                    'Language of the interface, the stories, the AI answers and the guide\'s voice.',
                  ),
                  style: const TextStyle(fontSize: 13, color: NmColors.muted),
                ),
                const SizedBox(height: 14),
                for (final lang in AppLang.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: controller.lang == lang
                              ? NmColors.ink
                              : NmColors.line,
                          width: controller.lang == lang ? 2 : 1,
                        ),
                      ),
                      title: Text(lang.nativeName,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      trailing: controller.lang == lang
                          ? const Icon(Icons.check_circle, color: NmColors.ink)
                          : null,
                      onTap: () async {
                        await controller.setLang(lang);
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
                    ),
                  ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: controller.analyticsEnabled,
                  onChanged: (v) => controller.setAnalyticsEnabled(v),
                  title: Text(
                    L.t('Анонімна статистика', 'Anonymous statistics'),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    L.t(
                      'Допомагає покращувати гід: які місця слухають, де трапляються збої. Без імені, пошти та координат.',
                      'Helps improve the guide: which places are heard, where things fail. No name, e-mail or coordinates.',
                    ),
                    style: const TextStyle(fontSize: 12, color: NmColors.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void _showReportSheet(
    BuildContext context, WalkController controller, Poi poi) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _ReportSheet(controller: controller, poi: poi),
  );
}

class _ReportSheet extends StatefulWidget {
  final WalkController controller;
  final Poi poi;

  const _ReportSheet({required this.controller, required this.poi});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportReason _reason = ReportReason.wrongFacts;
  final TextEditingController _comment = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    setState(() => _busy = true);
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    final ok = await widget.controller.reportPlace(widget.poi, _reason,
        comment: _comment.text, origin: origin);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.report_gmailerrorred_outlined,
                        color: NmColors.wine),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                          L.t('Неточна інформація', 'Inaccurate information'),
                          style: NmText.title(22)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '«${widget.poi.shownName}»',
                  style: const TextStyle(fontSize: 14, color: NmColors.muted),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in ReportReason.values)
                      ChoiceChip(
                        label: Text(r.label),
                        selected: _reason == r,
                        onSelected: (_) => setState(() => _reason = r),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _comment,
                  maxLength: 300,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: L.t('Що саме не так? (необов\'язково)',
                        'What exactly is wrong? (optional)'),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  L.t(
                    'Відкриється меню «Поділитися»: оберіть пошту чи месенджер, щоб надіслати повідомлення розробникам. У ньому лише це місце та що застосунок розповів про нього.',
                    'The share menu opens: pick mail or a messenger to send the message to the developers. It contains only this place and what the app said about it.',
                  ),
                  style: const TextStyle(
                      fontSize: 12, color: NmColors.muted, height: 1.35),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  style: NmButtons.primary(),
                  onPressed: _busy ? null : _send,
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: Text(
                    L.t('Надіслати', 'Send'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
