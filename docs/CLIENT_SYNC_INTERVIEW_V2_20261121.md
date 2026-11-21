# 隐藏访谈页面同步到实际 iOS 编译目录

## 问题与处理

截图中仍有左上角目录和“第 1 章 · 故乡的轮廓”，是因为此前客户端变更仅在独立工作区，而原目录 `ios/Flutter/Generated.xcconfig` 的 `FLUTTER_APPLICATION_PATH` 和 `FLUTTER_TARGET` 指向 `/Users/zhaoqing/myprojects/LifePages`。后端发布不会更新本地 Flutter 页面。

2026-11-21 将基于 `origin/android`（`e9e3ffd`）的共享 Flutter 客户端及访谈 v2 界面合入原项目的 `lib/`、`test/`，共 21 个文件。未向远程 Android 分支推送，未修改原目录的 Git 分支或提交，未覆盖其后端、原生工程和依赖文件。原目录用于编译客户端；访谈 v2 后端源码和部署记录仍位于独立工作区，不能用原目录旧后端覆盖已发布的 v2。

合并采用公共基线 `c67693a` 三方比较。原目录的永久会员标识、会员页面、并行会话恢复、`include_chat` 首屏加载优化均保留；新访谈优先读取访谈接口，避免首屏缓存绕回旧目录。所有聊天页面均不显示左上角目录或章节副标题。书架中的成书目录保持正常。

原文件备份、各文件合并前后 SHA-256、合并结果保存在独立工作区被忽略的 `artifacts/client-sync/`。37 个受保护文件（原后端 Python、Xcode 工程、会员弹窗及依赖文件）同步后哈希不变。

## 验证

实际编译和验证目录：`/Users/zhaoqing/myprojects/LifePages`。

- `flutter analyze --no-pub`：通过。
- `flutter test --no-pub --concurrency=1`：52 项通过。
- `flutter test --no-pub test/interview_v2_test.dart`：最终隐藏目录断言、首屏与刷新用例共 4 项通过。
- `flutter build ios --simulator --debug --no-codesign --no-pub`：通过，产物 `/Users/zhaoqing/myprojects/LifePages/build/ios/iphonesimulator/Runner.app`。构建记录保存在 `artifacts/client-sync/ios-build.log`。
- 测试明确断言旧聊天和 v2 均没有左上角目录按钮或章节副标题；v2 走实际首屏预加载入口，并覆盖刷新成功、网络重试和修订冲突。
- 未安装、启动或操作模拟器。由用户在原目录自行运行并验收真人录音、播报和阅读体验。
