# Android 本机开发与交接

## 基线与边界

- 集成分支：`android`；初始共同基线 `ef18107`。协作规则见根目录 [AGENTS.md](../AGENTS.md)。
- Flutter 基线：3.44.2，revision `c9a6c484230f8b5e408ec57be1ef71dee1e77020`，与仓库 `.metadata` 一致。Dart 3.12.2。不要执行 `flutter upgrade` 或 `flutter pub upgrade`。
- Android 包名 `com.caoyuming.lifepages`。SDK、Gradle 和 Flutter 的本机路径不提交；iOS 继续使用原包名和原生工程。
- 复用 `https://onesay.top/lifepages` 的设备凭证、邮箱账号和数据接口；不新建安卓账号库，不部署后端。
- 社交登录、选图、PDF 暂不接入 Android；会员页沿用现状，不代表支付已实现。
- 调试包仅用于开发。正式发布前必须另行配置发布签名、图标、支付及商店材料。

## Windows 环境

安装基线 Flutter、Android Studio 和 VS Code Flutter 扩展（含 Dart）。SDK Manager 安装 Android SDK Platform、Build-Tools、Platform-Tools、Command-line Tools、Emulator 和构建要求的 NDK/CMake。

```powershell
flutter doctor --android-licenses
flutter doctor -v
flutter pub get --enforce-lockfile
```

若锁文件不能满足解析，先排查 Flutter 版本、包源及下载错误；不要自动重写锁文件。仅做 Android 开发时不需要安装 Visual Studio C++ 工具链。

Device Manager 新建 Pixel 手机，名称 `LifePages_Pixel_API_36`，API 36、x86_64 系统镜像，2GB RAM、硬件加速。启用宿主机麦克风输入，并允许 Windows 麦克风访问。先运行 `emulator -accel-check`；当 Hyper-V 已在运行时，WMI 的固件虚拟化字段可能显示 false，不能据此断定需要调整 BIOS。

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Start-Android.ps1
flutter devices
flutter build apk --debug --target-platform android-arm64
flutter run -d <emulator-ID> --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk
```

在 VS Code 中，先选择 Android 模拟器，再选择 **LifePages Android (ARM64 RTC)** 配置，按 F5。该配置先构建 ARM64 APK，再通过 Flutter 启动该 APK。Mac 上开发 iOS 继续使用 **LifePages (selected device)**。

当前 RTC SDK 虽有部分 x86_64 库，但必需的 ByteNN 仅随 ARM 架构提供，因此普通 x86_64 调试包无法初始化 RTC。首轮固定打包 ARM64，使用 API 36 Google APIs 镜像的 ARM64 转译（`ro.product.cpu.abilist` 应包含 `arm64-v8a`，`ro.dalvik.vm.native.bridge` 为 `libndk_translation.so`）。Flutter 引擎也必须构建为 ARM64，不能直接用默认的 `flutter run -d emulator-5554` 重建 x86_64 引擎。

Android 构建单独配置火山 Maven、旧支持库转 AndroidX、兼容旧命名空间及 RTC 插件 compileSdk 36。ByteNN 所需 `libc++_shared.so` 从固定 NDK 自动复制到构建目录，不提交二进制库。原生依赖变化后必须停止运行并重新构建，热重载不够。

## 验收要求

仅使用专用测试邮箱账号及虚构资料。跨端测试需同一个应用账号；原先只绑定 Apple 的账号需先在 iOS 绑定邮箱，再从安卓登录，不按邮箱文本擅自合并身份。

1. 首次启动建立访客空间；文字流式回复正常，错误可重试。
2. 邮箱登录、访客绑定、重启保持会话、退出重登，书架和章节编辑保存正常。
3. 拒绝/允许麦克风、长按录音、上滑取消、转写、失败重试、原声回放。
4. RTC 手动播放、确认后的自动播报、历史重播、音色选择、开始录音停止播报、切书和后台释放。必须实际听到声音，构建成功或静音样本不能代替。
5. Mac iOS 测试实例使用同一测试账号，依次编辑后刷新，验证书稿一致；不要并发改同一章节测试不存在的冲突解决能力。
6. `flutter analyze`、`flutter test`、调试 APK 构建；Mac 独立 worktree 完成 iOS 构建及登录、录音、播报、选图、PDF 冒烟后，才合并共享变更。

Android 模拟器、Android 真机和 iOS 的结果必须分开记录。暂不支持的安卓入口不展示；已有图片及正文继续可读。

## 本轮结果

2026-11-15，Windows / API 36 Google APIs 模拟器 `LifePages_Pixel_API_36`：

- 已安装 Flutter 3.44.2、Android Studio、SDK/NDK/CMake、VS Code Flutter/Dart 扩展；WHPX 检查通过，模拟器正常启动。
- `flutter analyze --no-pub` 通过；全套 37 项测试通过。原有语音时序测试在 Windows 上偶发早于 WAV 写入完成便断言，现改为有上限地等待真实请求，保留精确请求数量断言。
- ARM64 调试 APK 构建、安装、启动通过。虚构访客内容发送到现有后端并收到 AI 回复；重新启动后聊天仍可见。
- 书架、章节编辑、保存、返回后重新进入读取通过；Android 不展示选图和 PDF 原生入口。
- RTC 播放进入实际运行状态；从应用内取得接收的 WAV，24kHz、288543 帧、约 12 秒，采样峰值 14035，确认实际接收了非静音音频。未把机器采样检测描述为人工听感验收。
- 麦克风系统授权、长按后上滑取消流程已操作。真实说话识别准确率、转写后原声回放、自动播报及音色切换仍需人工补验。
- 邮箱登录入口已接入原有后端；未提供专用测试账号，未发送验证码或读取真实账号书稿。实际登录/退出/跨端同步待专用账号验收。Android 隐藏尚未接入的社交登录入口。
- iOS 构建与运行、Android 真机均待验证。未修改 `ios/`、pubspec.yaml、pubspec.lock、原有 `.metadata` 或 server/；未合并 main、部署服务或迁移数据库。

本机截图及测试接收的音频保存在 Git 忽略的 `artifacts/`，APK 位于 `build/app/outputs/flutter-apk/app-debug.apk`。

## Mac 接手

协作规则独立草稿 PR：https://github.com/Sunming1126/LifePages/pull/1 。Mac 可先读取该 PR 的 AGENTS.md，审阅后再合并并拉取。

安卓分支使用独立提交区分 Android 工程、共享界面能力判断、RTC 开关和 Windows 测试等待修正。先 `git fetch origin`，在独立 worktree 检出 `origin/android` 验证，避免切换正在开发的 iOS 工作目录。iOS 冒烟通过后再处理安卓 PR；不要强推、直接覆盖或把 main 重置为 android。
