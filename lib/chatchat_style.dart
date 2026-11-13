// Presentation copied from ChatChat assistant_screen.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

const chatAccent = Color(0xFFE8735A);
const chatForeground = Color(0xFF2A2528);
const _assistantPaper = Color(0xfffffdfa);
const _assistantEdge = Color(0xffe8dfd2);
const _userPaper = Color(0xffeee1cf);
const _userEdge = Color(0xffe2d2bb);
const _messageLabel = Color(0xff755735);

ThemeData chatChatTheme(BuildContext context) => Theme.of(context).copyWith(
  colorScheme: ColorScheme.fromSeed(
    seedColor: chatAccent,
    surface: _assistantPaper,
  ),
);

class ChatChatMessageBubble extends StatelessWidget {
  final String text;
  final bool outgoing;
  final VoidCallback? onPlay;
  final VoidCallback? onRefresh;
  final bool playing, refreshing, canRefresh, selectable;
  const ChatChatMessageBubble({
    super.key,
    required this.text,
    required this.outgoing,
    this.onPlay,
    this.onRefresh,
    this.playing = false,
    this.refreshing = false,
    this.canRefresh = true,
    this.selectable = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubbleMaxWidth =
        MediaQuery.sizeOf(context).width * (outgoing ? .78 : .76);
    final textStyle = TextStyle(
      fontSize: 19,
      height: 1.48,
      color: theme.colorScheme.onSurface,
      fontWeight: FontWeight.w400,
    );
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: bubbleMaxWidth),
        margin: const EdgeInsets.only(bottom: 14),
        padding: EdgeInsets.fromLTRB(
          15,
          12,
          15,
          onPlay != null || onRefresh != null ? 4 : 12,
        ),
        decoration: BoxDecoration(
          color: outgoing ? _userPaper : _assistantPaper,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(22),
            topRight: const Radius.circular(22),
            bottomLeft: Radius.circular(outgoing ? 22 : 7),
            bottomRight: Radius.circular(outgoing ? 7 : 22),
          ),
          border: Border.all(color: outgoing ? _userEdge : _assistantEdge),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selectable)
              SelectableText(text, style: textStyle)
            else
              Text(text, style: textStyle),
            if (onPlay != null || onRefresh != null)
              Wrap(
                children: [
                  if (onPlay != null)
                    _action(
                      outgoing
                          ? '播放原声'
                          : playing
                          ? '停止 AI 语音'
                          : '播放 AI 语音',
                      Icon(
                        playing ? Icons.stop_rounded : Icons.volume_up_rounded,
                      ),
                      onPlay,
                    ),
                  if (onRefresh != null) ...[
                    _action(
                      refreshing ? '正在换问题' : '换一个问题',
                      refreshing
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded),
                      canRefresh && !refreshing ? onRefresh : null,
                    ),
                    _action(
                      '复制消息',
                      const Icon(Icons.content_copy_rounded),
                      () async {
                        await Clipboard.setData(ClipboardData(text: text));
                        if (context.mounted) {
                          ScaffoldMessenger.maybeOf(
                            context,
                          )?.showSnackBar(const SnackBar(content: Text('已复制')));
                        }
                      },
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _action(String tooltip, Widget icon, VoidCallback? onPressed) =>
      IconButton(
        tooltip: tooltip,
        color: _messageLabel,
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        icon: icon,
      );
}

class ChatChatThinkingBubble extends StatefulWidget {
  const ChatChatThinkingBubble({super.key});

  @override
  State<ChatChatThinkingBubble> createState() => ChatChatThinkingBubbleState();
}

class ChatChatThinkingBubbleState extends State<ChatChatThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = .5;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'AI 正在回复',
    liveRegion: true,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const ValueKey('assistant-thinking-bubble'),
        width: 72,
        height: 46,
        margin: const EdgeInsets.only(bottom: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _assistantPaper,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(22),
            bottomLeft: Radius.circular(9),
            bottomRight: Radius.circular(22),
          ),
          border: Border.fromBorderSide(BorderSide(color: _assistantEdge)),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, _) => Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(3, (index) {
              final reduced = MediaQuery.disableAnimationsOf(context);
              final strength = reduced
                  ? <double>[.45, .7, 1][index]
                  : _dot(_controller.value, index);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3.5),
                child: Transform.scale(
                  scale: reduced ? 1 : 1 + .15 * strength,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: chatForeground.withValues(
                        alpha: .38 + .62 * strength,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    ),
  );

  double _dot(double value, int index) {
    final shifted = (value - index * .18) % 1;
    return shifted < .55 ? (1 - (shifted * 2 - 1).abs()).clamp(0, 1) : 0;
  }
}

class ChatChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool canSubmit;
  final VoidCallback onSend;
  final FocusNode focusNode;
  final Widget? holdToTalk;
  final VoidCallback? onKeyboard;
  const ChatChatComposer({
    super.key,
    required this.controller,
    required this.canSubmit,
    required this.onSend,
    required this.focusNode,
    this.holdToTalk,
    this.onKeyboard,
  });
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final voiceMode = holdToTalk != null;
    return RepaintBoundary(
      child: DecoratedBox(
        key: const ValueKey('assistant-floating-composer'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? .28 : .11),
              blurRadius: 30,
              spreadRadius: -8,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: isDark ? .04 : .28),
              blurRadius: 18,
              spreadRadius: -10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: AdaptiveGlass(
          shape: const LiquidRoundedSuperellipse(borderRadius: 26),
          quality: GlassQuality.standard,
          allowElevation: false,
          settings: LiquidGlassSettings(
            blur: voiceMode ? 8 : 3,
            glassColor: voiceMode
                ? const Color(0x4DFFFFFF)
                : Colors.transparent,
            thickness: 24,
            glowIntensity: .5,
            lightIntensity: 1.55,
            fresnelStrength: .75,
            saturation: 1.2,
            refractiveIndex: 1.1,
          ),
          child: Container(
            key: const ValueKey('assistant-composer-surface'),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? .20 : .58),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child:
                        holdToTalk ??
                        TextField(
                          key: const ValueKey('assistant-text-input'),
                          controller: controller,
                          focusNode: focusNode,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) {
                            if (controller.text.trim().isNotEmpty &&
                                canSubmit) {
                              onSend();
                            }
                          },
                          style: const TextStyle(fontSize: 17, height: 1.35),
                          decoration: const InputDecoration(
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 10,
                            ),
                          ),
                        ),
                  ),
                  if (holdToTalk != null) ...[
                    const SizedBox(width: 6),
                    _action(
                      context,
                      key: const ValueKey('assistant-keyboard-mode'),
                      tooltip: '切换到文字输入',
                      icon: Icons.keyboard_rounded,
                      onPressed: onKeyboard,
                    ),
                  ] else
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (_, value, _) => _action(
                        context,
                        key: const ValueKey('assistant-send-button'),
                        tooltip: '发送',
                        icon: Icons.arrow_upward_rounded,
                        onPressed: canSubmit && value.text.trim().isNotEmpty
                            ? onSend
                            : null,
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

  Widget _action(
    BuildContext context, {
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return IconButton.filled(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: isDark ? .28 : .70),
        foregroundColor: theme.colorScheme.onSurface,
        disabledBackgroundColor: Colors.white.withValues(
          alpha: isDark ? .12 : .34,
        ),
        disabledForegroundColor: theme.colorScheme.onSurfaceVariant.withValues(
          alpha: .5,
        ),
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.all(10),
      ),
      icon: Icon(icon),
    );
  }
}
