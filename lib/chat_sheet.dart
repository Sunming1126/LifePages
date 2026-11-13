import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// Sheet surface and motion from ChatChat's assistant settings.
Future<T?> showChatSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool expanded = false,
}) => showModalBottomSheet<T>(
  context: context,
  useRootNavigator: true,
  useSafeArea: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(),
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: .24),
  showDragHandle: false,
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: Duration(milliseconds: 220),
          reverseDuration: Duration(milliseconds: 170),
        ),
  builder: (sheet) {
    final media = MediaQuery.of(sheet);
    final dark = Theme.of(sheet).brightness == Brightness.dark;
    return AnimatedPadding(
      duration: media.disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 160),
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: LayoutBuilder(
            builder: (_, constraints) {
              final height = constraints.maxHeight.clamp(
                0.0,
                media.size.height * .84,
              );
              return ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: constraints.maxWidth,
                  maxHeight: height,
                  minHeight: expanded ? height : 0,
                ),
                child: AdaptiveGlass(
                  key: const ValueKey('chat-bottom-sheet'),
                  shape: const LiquidRoundedSuperellipse(borderRadius: 30),
                  quality: GlassQuality.standard,
                  useOwnLayer: false,
                  allowElevation: false,
                  settings: const LiquidGlassSettings(
                    blur: 10,
                    thickness: 20,
                    glowIntensity: .72,
                    lightIntensity: 1.48,
                    fresnelStrength: .86,
                    saturation: .12,
                    refractiveIndex: 1.1,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: dark ? .68 : .84),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: dark ? .28 : .70),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: dark ? .28 : .10,
                          ),
                          blurRadius: 30,
                          spreadRadius: -12,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 36,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .18),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Flexible(child: builder(sheet)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  },
);

class ChatSheetDialog extends StatelessWidget {
  const ChatSheetDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DefaultTextStyle(
        style: Theme.of(
          context,
        ).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w800),
        child: title,
      ),
      const SizedBox(height: 12),
      Flexible(child: SingleChildScrollView(child: content)),
      const SizedBox(height: 12),
      OverflowBar(
        alignment: MainAxisAlignment.end,
        spacing: 8,
        overflowSpacing: 4,
        children: actions,
      ),
    ],
  );
}
