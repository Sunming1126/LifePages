import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/chat_sheet.dart';

void main() {
  testWidgets('glass sheet covers the navigation and avoids the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return Stack(
                children: [
                  const Positioned(
                    left: 18,
                    right: 18,
                    bottom: 48,
                    height: 64,
                    child: ColoredBox(color: Colors.blue, key: ValueKey('nav')),
                  ),
                  Center(
                    child: TextButton(
                      onPressed: () async {
                        result = await showChatSheet<String>(
                          context: context,
                          builder: (sheet) => ChatSheetDialog(
                            title: const Text('编辑'),
                            content: const TextField(),
                            actions: [
                              FilledButton(
                                onPressed: () => Navigator.pop(sheet, 'saved'),
                                child: const Text('保存'),
                              ),
                            ],
                          ),
                        );
                      },
                      child: const Text('打开'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    final nav = tester.getRect(find.byKey(const ValueKey('nav')));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('chat-bottom-sheet'));
    final rect = tester.getRect(surface);
    expect(rect.intersect(nav), nav);
    expect(rect.bottom, 844 - 34 - 12);

    await tester.tap(find.byType(TextField));
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.getRect(surface).bottom, 844 - 300 - 12);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, 'saved');
    expect(surface, findsNothing);
  });
}
