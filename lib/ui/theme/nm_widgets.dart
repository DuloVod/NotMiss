import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/place_photo_service.dart';
import 'app_theme.dart';

/// Icons drawn for the NotMiss design (assets/icons/*.png, black on transparent).
///
/// They are tinted in code, so one file serves every colour.
enum NmIcons {
  ai,
  back,
  check,
  down,
  flag,
  headphones,
  language,
  locate,
  pause,
  pin,
  places,
  play,
  refresh,
  replay,
  right,
  send,
  stop,
  up,
  volume,
  walk,
  wave;

  AssetImage get image => AssetImage('assets/icons/$name.png');
}

/// One design icon in the given colour.
class NmIcon extends StatelessWidget {
  final NmIcons icon;
  final double size;
  final Color color;

  const NmIcon(this.icon, {super.key, this.size = 22, this.color = NmColors.ink});

  @override
  Widget build(BuildContext context) =>
      ImageIcon(icon.image, size: size, color: color);
}

/// A round icon button (white with a soft shadow on the map, flat on sheets).
class NmCircleButton extends StatelessWidget {
  final Widget child;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Color background;
  final bool shadow;

  const NmCircleButton({
    super.key,
    required this.child,
    required this.tooltip,
    required this.onPressed,
    this.size = 44,
    this.background = NmColors.surface,
    this.shadow = true,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: background,
          shape: BoxShape.circle,
          boxShadow: shadow ? nmShadow : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// A small cream pill with dark text, e.g. «Ви поруч із цікавим місцем».
class NmBadge extends StatelessWidget {
  final String text;
  final NmIcons? icon;
  final IconData? materialIcon;

  const NmBadge(this.text, {super.key, this.icon, this.materialIcon});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: NmColors.cream,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            NmIcon(icon!, size: 15),
            const SizedBox(width: 6),
          ] else if (materialIcon != null) ...[
            Icon(materialIcon, size: 15, color: NmColors.ink),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: NmColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// White button with wine text and a thin wine outline: «Завершити прогулянку».
class NmEndWalkButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const NmEndWalkButton({super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const NmIcon(NmIcons.flag, size: 20, color: NmColors.wine),
        label: Text(label),
        style: ButtonStyle(
          backgroundColor: const WidgetStatePropertyAll(NmColors.surface),
          foregroundColor: const WidgetStatePropertyAll(NmColors.wine),
          overlayColor: WidgetStatePropertyAll(NmColors.wine.withValues(alpha: 0.06)),
          side: const WidgetStatePropertyAll(
              BorderSide(color: NmColors.wineLine, width: 1.5)),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          textStyle: const WidgetStatePropertyAll(NmText.button),
          elevation: const WidgetStatePropertyAll(0),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 22)),
        ),
      ),
    );
  }
}

/// A dot that gently pulses: the walk is on / the guide is listening.
class NmPulse extends StatefulWidget {
  final double size;
  final Color color;
  final Color halo;
  final Widget? child;

  const NmPulse({
    super.key,
    required this.size,
    this.color = NmColors.ink,
    this.halo = NmColors.cream,
    this.child,
  });

  @override
  State<NmPulse> createState() => _NmPulseState();
}

class _NmPulseState extends State<NmPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect "reduce motion" in the phone's accessibility settings.
    if (MediaQuery.of(context).disableAnimations) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value;
              return Transform.scale(
                scale: 0.6 + t,
                child: Opacity(
                  opacity: (0.55 * (1 - t)).clamp(0.0, 1.0),
                  child: Container(
                    width: s,
                    height: s,
                    decoration: BoxDecoration(color: widget.halo, shape: BoxShape.circle),
                  ),
                ),
              );
            },
          ),
          widget.child ??
              Container(
                width: s,
                height: s,
                decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
              ),
        ],
      ),
    );
  }
}

/// The "story is playing" wave: bars that bounce while the guide speaks.
///
/// [progress] (0…1) colours the bars already heard in ink, the rest in sand.
class NmWave extends StatefulWidget {
  final bool playing;
  final double progress;
  final double height;
  final int bars;
  final Color color;
  final Color restColor;
  final double barWidth;
  final bool spread;

  const NmWave({
    super.key,
    required this.playing,
    this.progress = 1,
    this.height = 28,
    this.bars = 40,
    this.color = NmColors.ink,
    this.restColor = NmColors.sand,
    this.barWidth = 3,
    this.spread = true,
  });

  @override
  State<NmWave> createState() => _NmWaveState();
}

class _NmWaveState extends State<NmWave> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  // Bar heights from the design, repeated.
  static const _shape = [8, 14, 20, 12, 24, 16, 10, 22, 28, 18, 12, 20, 26, 14, 10, 18];

  void _sync() {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.playing && !reduce) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant NmWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final heard = (widget.progress.clamp(0.0, 1.0) * widget.bars).round();
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Row(
            mainAxisAlignment:
                widget.spread ? MainAxisAlignment.spaceBetween : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < widget.bars; i++) ...[
                if (!widget.spread && i > 0) const SizedBox(width: 2),
                Builder(builder: (_) {
                  final base = _shape[i % _shape.length] / 28.0;
                  // Each bar moves on its own phase, like the CSS animation-delay.
                  final phase = (_c.value + (i % 5) * 0.2) % 1.0;
                  final wobble = widget.playing ? 0.35 + 0.65 * math.sin(phase * math.pi) : 1.0;
                  final h = (widget.height * base * wobble).clamp(3.0, widget.height);
                  return Container(
                    width: widget.barWidth,
                    height: h,
                    decoration: BoxDecoration(
                      color: i < heard ? widget.color : widget.restColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  );
                }),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Compass button face: a ring with a red (north) and grey needle, turned with the map.
class NmCompass extends StatelessWidget {
  /// Map rotation in degrees (flutter_map's camera.rotation).
  final double mapRotation;
  final double size;

  const NmCompass({super.key, required this.mapRotation, this.size = 30});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _CompassPainter(mapRotation * math.pi / 180),
    );
  }
}

class _CompassPainter extends CustomPainter {
  final double angle;
  _CompassPainter(this.angle);

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 28;
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
      c,
      11.5 * k,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 * k
        ..color = NmColors.compassRing,
    );
    canvas.save();
    canvas.translate(c.dx, c.dy);
    // The needle points to north on the screen: against the map's own rotation.
    canvas.rotate(-angle);
    final north = Path()
      ..moveTo(0, -8.5 * k)
      ..lineTo(3.4 * k, 0)
      ..lineTo(-3.4 * k, 0)
      ..close();
    final south = Path()
      ..moveTo(0, 8.5 * k)
      ..lineTo(3.4 * k, 0)
      ..lineTo(-3.4 * k, 0)
      ..close();
    canvas.drawPath(north, Paint()..color = NmColors.compassRed);
    canvas.drawPath(south, Paint()..color = NmColors.compassGrey);
    canvas.restore();
    canvas.drawCircle(c, 1.6 * k, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _CompassPainter old) => old.angle != angle;
}

/// Rounded tile with the place's photo; the kind icon on cream while it loads or when there
/// is no photo.
class NmPlaceThumb extends StatelessWidget {
  final IconData icon;
  final double size;
  final double radius;
  final String? imageUrl;

  const NmPlaceThumb({
    super.key,
    required this.icon,
    this.size = 60,
    this.radius = 20,
    this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final placeholder = Center(child: Icon(icon, size: size * 0.45, color: NmColors.ink));
    final url = imageUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        color: NmColors.cream,
        child: url == null
            ? placeholder
            : Image.network(
                url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                headers: PlacePhotoService.imageHeaders,
                // A thumbnail needs only a small decoded copy.
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
                excludeFromSemantics: true,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : placeholder,
                errorBuilder: (context, error, stack) => placeholder,
              ),
      ),
    );
  }
}

/// The large photo at the top of a place's screen, with its author and licence.
class NmPlaceHero extends StatelessWidget {
  final IconData icon;
  final PlacePhoto? photo;

  /// "Фото: Вікіпедія · Author · CC BY-SA 4.0"
  final String? caption;

  /// Room left at the bottom for the white sheet that overlaps the photo.
  final double bottomOverlap;

  const NmPlaceHero({
    super.key,
    required this.icon,
    required this.photo,
    this.caption,
    this.bottomOverlap = 34,
  });

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: NmColors.cream,
      child: Center(
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomOverlap),
          child: Icon(icon, size: 64, color: NmColors.stone),
        ),
      ),
    );
    final p = photo;
    if (p == null) return placeholder;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          p.url,
          fit: BoxFit.cover,
          headers: PlacePhotoService.imageHeaders,
          excludeFromSemantics: true,
          frameBuilder: (context, child, frame, sync) => sync
              ? child
              : AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 250),
                  child: child,
                ),
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : Stack(fit: StackFit.expand, children: [placeholder, child]),
          errorBuilder: (context, error, stack) => placeholder,
        ),
        if (caption != null)
          Positioned(
            right: 16,
            bottom: bottomOverlap + 16,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
              child: Tooltip(
                message: caption!,
                child: Container(
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0x8C1B1A17), // ink at 55%
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    caption!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Ukrainian plural: 1 історія, 2 історії, 5 історій (21 історія, 12 історій…).
String ukPlural(int n, String one, String few, String many) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}
