// Live transcription dock adapted from OneSay main_shell.dart.
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'main.dart' as life;

class HoldToTalkButton extends StatefulWidget {
  const HoldToTalkButton({
    super.key,
    required this.active,
    required this.onStart,
    required this.onSlide,
    required this.onEnd,
    required this.onCancel,
    this.label = '长按说话',
    this.hint = '松开发送，上滑取消',
    this.child,
  });

  final bool active;
  final VoidCallback onStart;
  final ValueChanged<bool> onSlide;
  final VoidCallback onEnd;
  final VoidCallback onCancel;
  final String label, hint;
  final Widget? child;

  @override
  State<HoldToTalkButton> createState() => _HoldToTalkButtonState();
}

class _HoldToTalkButtonState extends State<HoldToTalkButton> {
  int? pointer;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    hint: widget.hint,
    child: Listener(
      onPointerDown: (event) => pointer ??= event.pointer,
      onPointerUp: (event) {
        if (pointer == event.pointer) pointer = null;
      },
      onPointerCancel: (event) {
        if (pointer != event.pointer) return;
        pointer = null;
        widget.onCancel();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (_) => widget.onStart(),
        onLongPressMoveUpdate: (details) =>
            widget.onSlide(details.offsetFromOrigin.dy < -40),
        onLongPressEnd: (_) => widget.onEnd(),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          alignment: Alignment.center,
          child: ExcludeSemantics(
            child:
                widget.child ??
                Text(
                  widget.active ? '松手结束' : '长按说话',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
          ),
        ),
      ),
    ),
  );
}

// ─── Voice Dock Capsule ─────────────────────────────────────

class OneSayVoiceDock extends StatefulWidget {
  final String text;
  final String status;
  final String hint;
  final double amp;
  final bool isCancel;
  final bool isProcessing;
  final bool hasError;

  const OneSayVoiceDock({
    super.key,
    required this.text,
    required this.status,
    required this.hint,
    required this.amp,
    required this.isCancel,
    required this.isProcessing,
    required this.hasError,
  });

  @override
  State<OneSayVoiceDock> createState() => OneSayVoiceDockState();
}

class OneSayVoiceDockState extends State<OneSayVoiceDock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  // 实时识别文本的滚动控制器：文本变长时自动滚到底部，让用户看到最新内容。
  final ScrollController _textScrollCtrl = ScrollController();
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    _entry.forward();
    _lastText = widget.text;
  }

  @override
  void didUpdateWidget(covariant OneSayVoiceDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != _lastText) {
      _lastText = widget.text;
      // 等当前帧布局完成后再滚动，否则 maxScrollExtent 还是旧的。
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
    }
  }

  void _jumpToEnd() {
    if (!mounted || !_textScrollCtrl.hasClients) return;
    final max = _textScrollCtrl.position.maxScrollExtent;
    if (max <= 0) return;
    _textScrollCtrl.animateTo(
      max,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _entry.dispose();
    _textScrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.hasError || widget.isCancel
        ? Colors.redAccent
        : life.accent;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return AnimatedBuilder(
      animation: _entry,
      builder: (context, _) {
        final raw = reduceMotion ? 1.0 : _entry.value;
        final bloom = Curves.elasticOut.transform(
          Interval(0.0, 0.46).transform(raw).clamp(0.0, 1.0),
        );
        final stretch = Curves.easeOutBack.transform(
          Interval(0.36, 1.0).transform(raw).clamp(0.0, 1.0),
        );
        final fade = Curves.easeOutCubic.transform(
          Interval(0.02, 0.42).transform(raw).clamp(0.0, 1.0),
        );
        final contentFade = fade;
        final circleWidth = lerpDouble(0.06, 0.27, bloom)!;
        final heightScale = lerpDouble(0.24, 1.0, bloom)!;
        final widthFactor = lerpDouble(circleWidth, 1.0, stretch)!;
        return Opacity(
          opacity: fade,
          child: Transform.translate(
            offset: Offset(42 * (1 - bloom), 18 * (1 - bloom)),
            child: Transform.scale(
              alignment: Alignment.bottomRight,
              scaleY: heightScale,
              child: ClipRect(
                child: Align(
                  alignment: Alignment.bottomRight,
                  widthFactor: widthFactor,
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    scale: widget.isCancel ? 0.965 : 1.0,
                    child: _VoiceDockSurface(
                      text: widget.text,
                      status: widget.status,
                      hint: widget.hint,
                      amp: widget.amp,
                      accent: accent,
                      isCancel: widget.isCancel,
                      isProcessing: widget.isProcessing,
                      hasError: widget.hasError,
                      contentOpacity: contentFade,
                      textScrollCtrl: _textScrollCtrl,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VoiceDockSurface extends StatelessWidget {
  final String text;
  final String status;
  final String hint;
  final double amp;
  final Color accent;
  final bool isCancel;
  final bool isProcessing;
  final bool hasError;
  final double contentOpacity;
  final ScrollController textScrollCtrl;

  const _VoiceDockSurface({
    required this.text,
    required this.status,
    required this.hint,
    required this.amp,
    required this.accent,
    required this.isCancel,
    required this.isProcessing,
    required this.hasError,
    required this.contentOpacity,
    required this.textScrollCtrl,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = hasError || isCancel ? Colors.redAccent : life.ink;
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 110, maxHeight: 210),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: isCancel ? 0.90 : 0.84),
                accent.withValues(alpha: isCancel ? 0.13 : 0.07),
                Colors.white.withValues(alpha: 0.72),
              ],
              stops: const [0.0, 0.58, 1.0],
            ),
            border: Border.all(
              color: accent.withValues(alpha: isCancel ? 0.34 : 0.20),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: isCancel ? 0.16 : 0.11),
                blurRadius: 30,
                offset: const Offset(0, 13),
                spreadRadius: -10,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
                blurRadius: 22,
                offset: const Offset(0, 10),
                spreadRadius: -12,
              ),
            ],
          ),
          child: Opacity(
            opacity: contentOpacity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _VoicePulseDot(
                      accent: accent,
                      isCancel: isCancel,
                      isProcessing: isProcessing,
                      hasError: hasError,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: Colors.black54.withValues(alpha: 0.9),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 60),
                  child: SingleChildScrollView(
                    controller: textScrollCtrl,
                    physics: const BouncingScrollPhysics(),
                    child: Text(
                      text,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        height: 1.34,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _VoiceWaveform(
                  amp: amp,
                  accent: accent,
                  isCancel: isCancel,
                  isProcessing: isProcessing,
                  hasError: hasError,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Voice Waveform ─ 铺满镜像声纹，颜色走 accent（跟随主题）──────────
class _VoiceWaveform extends StatefulWidget {
  final double amp;
  final Color accent;
  final bool isCancel;
  final bool isProcessing;
  final bool hasError;

  const _VoiceWaveform({
    required this.amp,
    required this.accent,
    required this.isCancel,
    required this.isProcessing,
    required this.hasError,
  });

  @override
  State<_VoiceWaveform> createState() => _VoiceWaveformState();
}

class _VoiceWaveformState extends State<_VoiceWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat();
  double _disp = 0.2;

  @override
  void initState() {
    super.initState();
    _anim.addListener(_onTick);
  }

  void _onTick() {
    final raw = widget.amp.isFinite
        ? widget.amp.clamp(0.0, 1.0).toDouble()
        : 0.2;
    final target = widget.isProcessing
        ? 0.06
        : widget.hasError
        ? 0.0
        : raw;
    _disp += (target - _disp) * 0.16;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _anim.removeListener(_onTick);
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return SizedBox(
      width: double.infinity,
      height: 30,
      child: CustomPaint(
        painter: _VoiceWaveformPainter(
          progress: reduceMotion ? 0.0 : _anim.value,
          amp: _disp,
          accent: widget.accent,
          isCancel: widget.isCancel,
          isProcessing: widget.isProcessing,
          hasError: widget.hasError,
        ),
      ),
    );
  }
}

class _VoiceWaveformPainter extends CustomPainter {
  final double progress;
  final double amp;
  final Color accent;
  final bool isCancel;
  final bool isProcessing;
  final bool hasError;

  _VoiceWaveformPainter({
    required this.progress,
    required this.amp,
    required this.accent,
    required this.isCancel,
    required this.isProcessing,
    required this.hasError,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const count = 48;
    const gap = 1.6;
    final barW = (size.width - gap * (count - 1)) / count;
    final color = isCancel || hasError
        ? Colors.redAccent
        : isProcessing
        ? Colors.black54
        : accent;
    final alpha = isProcessing ? 0.45 : 0.85;
    final paint = Paint()..color = color.withValues(alpha: alpha);
    final midY = size.height / 2;
    final a = amp.clamp(0.0, 1.0).toDouble();
    for (var i = 0; i < count; i++) {
      final t = i / (count - 1);
      final env = math.sin(t * math.pi); // 中间高、两端低（镜像包络）
      final wig =
          0.35 + 0.65 * (math.sin(progress * 2 * math.pi * 2 + i * 0.5)).abs();
      var h = 3 + env * wig * a * 26;
      if (h > size.height) h = size.height;
      final x = i * (barW + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x + barW / 2, midY),
          width: barW,
          height: h,
        ),
        const Radius.circular(99),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceWaveformPainter old) => true;
}

// ─── Voice Pulse Dot ─ 状态行呼吸点，颜色走 accent（跟随主题）──────────
class _VoicePulseDot extends StatefulWidget {
  final Color accent;
  final bool isCancel;
  final bool isProcessing;
  final bool hasError;

  const _VoicePulseDot({
    required this.accent,
    required this.isCancel,
    required this.isProcessing,
    required this.hasError,
  });

  @override
  State<_VoicePulseDot> createState() => _VoicePulseDotState();
}

class _VoicePulseDotState extends State<_VoicePulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final color = widget.isCancel || widget.hasError
        ? Colors.redAccent
        : widget.accent;
    return SizedBox(
      width: 10,
      height: 10,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return CustomPaint(
            painter: _PulseDotPainter(
              progress: reduceMotion ? 0.0 : _c.value,
              color: color,
            ),
          );
        },
      ),
    );
  }
}

class _PulseDotPainter extends CustomPainter {
  final double progress;
  final Color color;

  _PulseDotPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(c, 3.4, Paint()..color = color);
    final ringR = 3.4 + progress * 5.5;
    final ringA = (1 - progress) * 0.5;
    canvas.drawCircle(
      c,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: ringA.clamp(0.0, 1.0)),
    );
  }

  @override
  bool shouldRepaint(covariant _PulseDotPainter old) =>
      old.progress != progress || old.color != color;
}
