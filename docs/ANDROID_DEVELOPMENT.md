# Android 本机开发与交接

## 基线与边界

- 集成分支：`android`；初始共同基线 `ef18107`。协作规则见根目录 [AGENTS.md](../AGENTS.md)。
- Flutter 基线：3.44.2，revision `c9a6c484230f8b5e408ec57be1ef71dee1e77020`，与仓库 `.metadata` 一致。Dart 3.12.2。不要执行 `flutter upgrade` 或 `flutter pub upgrade`。
- Android 包名 `com.caoyuming.lifepages`。SDK、Gradle 和 Flutter 的本机路径不提交；iOS 继续使用原包名和原生工程。
- 复用 `https://onesay.top/lifepages` 的设备凭证、邮箱账号和数据接口；不新建安卓账号库，不部署后端。
- 社交登录、选图暂不接入 Android；会员页沿用现状，不代表支付已实现。安卓已支持成书和系统“保存为 PDF”。
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

## 2026-11-17 同步与语音验收准备

- 合入远程 main 的 `e7acbc3`（Add illustrated page backgrounds），合并提交 `7c3c7d2`。保留新版三套插画背景、跨页背景偏好及旧偏好回退断言，同时保留安卓分支的 iOS 平台测试标记和 RTC 适配。pubspec.yaml 仅新增上游背景资源目录；未升级插件或改动锁文件。
- 锁文件校验、静态分析、37 项 Flutter 测试均通过。ARM64 Debug 与 Profile APK 均已构建；本机模拟器当前安装 Profile 包，路径 `build/app/outputs/flutter-apk/app-profile.apk`。
- 启用宿主机麦克风需要 `adb -s emulator-5554 emu avd hostmicon`；已验证返回 OK，应用 RECORD_AUDIO 为 foreground。启动脚本现在在设备启动完成后自动执行该配置，不会自动开始录音。
- 此轮首次启动遇到模拟器焦点分发超时及残留 ANR 对话框，重启模拟器（保留数据）后已恢复，重新检查聊天页面及播放/录音入口可响应。若再次出现，保留实际错误记录，不能简单视为功能验收通过。
- **真人转写及原声回听尚待本次现场录音或用户提供的真人样本。** 未使用静音、TTS 或模拟回调冒充真人测试；此前的非静音 RTC 接收证据属于 11-15 的验收记录，不是本轮真人录音证据。
- 现场步骤：在当前模拟器聊天页按住“说话”读一段虚构经历，松手后确认转写文本、AI 回复及录音消息保存；长按已保存的语音消息回听；重启 App 后再次回听。另验收上滑取消不发送、网络中断后保留录音并可重试。开始实际录音前确认 Windows 允许桌面应用访问麦克风。
- 本轮不修改 iOS 原生工程，不合并 main，不部署服务端；真人验收完成前保持安卓 PR 为草稿。

## 成书和 PDF 二维码验收（main 6f552a8）

- 合入 main 的 iOS 图标更新和 iOS PDF 二维码修复（`8277b87`、`6f552a8`）；安卓自身未改写 iOS 原生实现。
- Android 原先隐藏的成书/PDF 入口现已启用，通过 `life_pages/print` 原生通道打开系统打印预览，选择“Save as PDF / 保存为 PDF”可保存文件。可打印中文、长正文分页、已有章节图片及原声二维码；无原声章节不生成空二维码。纸张采用 A4 排版。
- Android 导出参数额外携带原声链接的 QR 模块矩阵（M 纠错）；iOS 导出参数及绘制实现保持原有行为。原生渲染为矢量黑白码，四模块留白；二维码空间不足时换页，不覆盖正文或图片。打印指定页时只输出所选页。
- 自动检查：静态分析通过，38 项 Flutter 测试通过，包含 Android 与 iOS 成书生成分享链接、原声链接/二维码参数及无原声章节行为的检查。
- 实机系统流程验证在本机 API 36 模拟器进行：隔离夹具 `tool/book_print_smoke.dart`（不访问后端、不读取真实书稿）点击“成书 → 开始成书 → 保存为 PDF”，导出 9 页。100 段长中文正文分页、图片正常；第 8 页含二维码，第 9 页无原声章节无二维码。将 PDF 以 216dpi 渲染并用 ZXing 解码，第 8 页得到 `https://example.org/lifepages/fictional-audio-check`，与夹具 URL 一致。该虚构链接仅验证二维码排版/编码，不代表测试了真实音频链接的播放或撤销。
- PDF 和扫码图位于本机 Git 忽略的 `artifacts/lifepages-book-check.pdf`、`artifacts/book-qr-page.png`。正式交付 APK 必须用 `-t lib/main.dart` 构建；不可将夹具入口 APK 当正常 App 交付。
- 本次交付为内部测试签名的 ARM64 Profile APK；与已验证的 Profile 构建模式一致，非商店发布包。iOS 运行仍待 Mac 回归；PR 保持草稿，不自动合并 main。

## Mac 接手

协作规则独立草稿 PR：https://github.com/Sunming1126/LifePages/pull/1 。Mac 可先读取该 PR 的 AGENTS.md，审阅后再合并并拉取。

安卓分支使用独立提交区分 Android 工程、共享界面能力判断、RTC 开关和 Windows 测试等待修正。先 `git fetch origin`，在独立 worktree 检出 `origin/android` 验证，避免切换正在开发的 iOS 工作目录。iOS 冒烟通过后再处理安卓 PR；不要强推、直接覆盖或把 main 重置为 android。
# 2026-11-17 晚间体验修复与成书同步

- 分支：`android`；合入共同基线 `c67693a`（问答配对整理成书），合并提交 `127a164`。图标独立提交 `5dc9378`；共享启动、缓存、播报修复 `6bf7479`；重连保留输入草稿 `da0c27a`。未修改 iOS 原生文件、Flutter 或依赖版本，未合并 main。
- 共享修改范围为 `lib/main.dart`、`lib/chat_shell.dart`、`lib/my_page.dart`、新增本地只读缓存和播报偏好模块及缓存测试。安卓优先显示首帧，再初始化玻璃效果；已有会话先显示上次成功加载的书架和聊天，后台刷新。网络读请求及首装访客创建有 8 秒等待上限。首次安装仍需联网创建访客；缓存不是完整离线数据库，音频、图片下载、发送及成书仍需联网。
- 缓存存于应用私有目录，按服务器与凭证散列隔离；401/服务端错误不会用旧缓存掩盖，失败写操作也不会伪装成功。重连保留输入草稿。Android 备份保持关闭；缓存与用户内容不入库。
- 安卓自动播报偏好默认开启，首次使用沿用语音服务数据授权；拒绝后关闭自动播报，可在「我的 → AI 回复自动播报」重新打开。收到服务端已提交的 SSE done 后直接更新消息，去掉结束时额外拉取历史的等待，保留 iOS 原有路径。该调整不承诺消除模型、网络或语音服务延迟。
- 图标从仓库既有 iOS 1024px 图导出 Android 各密度图及自适应/单色图层，不修改 iOS 资源。API 36 模拟器应用抽屉已看到书本声波图标。
- 模拟器实测：在线加载既有虚构测试书稿；关闭 Wi-Fi 与移动数据并强制结束后重启，书架正常显示缓存，聊天显示离线重连提示；恢复网络并重连后发送虚构英文测试文本，收到 AI 回复且出现「停止 AI 语音」，系统 AudioTrack 记录输出 620160 帧。自动播报开关默认 checked=true。未把这些检查当作真人录音转写或真机听感验收。
- 后端测试在 WSL Ubuntu 隔离虚拟环境运行 `python -m unittest server.test_books server.test_book_manuscript server.test_app`，22 项通过；测试使用临时数据库及模拟模型。远程新增代码仅涉及后端，APK 不携带 Python 服务；线上新成书行为以服务端实际部署版本为准，本机未部署生产服务。
- Windows 无法验证 iOS 构建，合并 main 前仍须 Mac 完成规则要求的 iOS 冒烟验证。原生 PDF 排版和二维码实现未改动；此前分页二维码解码验收见下方记录。
- 修复后的 `flutter analyze --no-pub` 无问题，`flutter test --no-pub` 42 项通过。Release 的 Java/R8 压缩因锁定 RTC 包引用未提供的可选厂商/JSON 类而失败；安卓构建独立提交 `7b20af6` 关闭 Java 压缩和资源裁剪，保留 JNI/反射代码及现有依赖，Dart 仍使用 Release AOT。APK 使用原本机测试签名，非商店签名。
- 最终交付使用正常 `lib/main.dart` 入口：`flutter build apk --release --no-pub --target-platform android-arm64 --build-number 4 -t lib/main.dart`。文件 `output/LifePages-Android-ARM64-20261117-v4.apk`，61,241,662 字节（58.4 MiB），SHA256 `ad62db8fea4f9c8687d0fda0de02d4003641211c2309d5fe8cc8867447b22033`。包名 `com.caoyuming.lifepages`，0.1.0 / versionCode 4，Android 7.0/API 24 起，ARM64；APK v2 签名校验通过。
- 最终 Release 包在模拟器覆盖安装成功、保留原虚构书稿。再次关闭双网络并强制结束重启，首帧 1.954 秒；安装后的首次启动 11.506 秒，故不据此承诺所有设备均 2 秒启动。断网输入 `Fictional offline draft.`，联网刷新后输入仍在；发送后收到新回复并自动启动语音播放。模拟器网络已恢复。截图/XML 等验收产物留在忽略的 `artifacts/`，APK/测试虚拟环境位于忽略的 `output/`。
# 2026-11-18 登录接入范围

安卓分支基于 `d5383e9`，本次计划修改 `android/` 的 Google Services 插件配置及共享的 `lib/account/social_sign_in.dart` 和相关测试；邮箱验证码、密码、注册、重设密码继续调用既有服务端接口。Firebase 本机配置不提交；等待安卓签名登记后的 JSON、Apple Services ID 与回调核对、专用测试账号和 Mac 双端验收。无需修改 iOS 原生工程或生产后端。

已将远端配置提交 `1b8c7fa` 合入本地 `android`（合并提交 `f2126ed`，共同基线 `c67693a`）。确认项目 `lifepages-980b0`、包名 `com.caoyuming.lifepages`、Web OAuth 客户端和匹配 APK 证书的 Android OAuth 客户端。Apple 配置按项目方提供的 `com.caoyuming.lifePages.signin` 和 `https://lifepages-980b0.firebaseapp.com/__/auth/handler` 核对格式，Android 继续使用 `AppleAuthProvider` 和线上 `https://onesay.top/lifepages`。

- `bd041ad` 移除 Android 登录页隐藏按钮的判断，复用 iOS 的 Apple 和 Google 按钮样式。API 36 模拟器显示四种登录入口，Google 可打开系统授权页并返回取消。Apple 启动 Firebase `GenericIdpActivity`，本次模拟器未到达 Apple 网页，结束进程后重新打开登录页。四种方式的线上成功登录、退出、重启恢复和同一已绑定账号的双端书架对照待实测。
- `f28b5d5` 限制 Android 松手后等待实时转写连接及结果的时间。在实时连接中断或未返回完整结果时，用保留的 WAV 调用现有 `/api/transcribe`，随后发送文字和原录音。转写超时提示重试，录音留在待发记录。Android 回归测试模拟实时结果未返回并验证备用转写和原录音随同一次请求发送。真机语音耗时待测。
- ARM64 Release 安装包 `output/LifePages-Android-ARM64-20261118-v7.apk`（versionCode 7），已覆盖安装到 `emulator-5554`。实际签名为原本机 Android Debug 测试签名。证书 SHA-1 为 `73:BA:AA:17:89:49:A6:25:3D:88:60:B9:40:FB:BF:7F:65:78:0E:49`，SHA-256 为 `CF:2B:1B:90:30:12:B7:02:7E:43:0E:AB:FC:8A:B0:4F:B6:66:AD:66:71:B6:0E:BD:D1:4C:CA:C5:0D:D5:D0:FC`。`apksigner` 验证通过，APK 内包含 Google Services 生成的资源。Mac 冒烟验收待执行。
- AI 延迟复测使用线上独立访客和虚构文字、静音 WAV。无 WAV、关闭播报时首字 2.89/3.02 秒。文字加播报一轮中，RTC 云任务 2.99 秒就绪，首字 4.29 秒，首段可播报文字 4.40 秒，首段 TTS 指令 5.33 秒获确认。测试未加入原生 RTC 房间，指令确认时间不等于首次出声。关闭播报、附 2 秒和 6 秒 WAV，响应头分别在 3.72 和 32.33 秒到达，首字在 4.96 和 34.85 秒到达。15 秒 WAV 两次触发客户端上传写超时。此为本机到现网的有限样本，不代表所有设备的耗时，也不含语音识别。
- 共享后端 `server/app.py` 流式模型请求使用进程内 HTTPS 连接池。每条消息仍单独提交原上下文，模型、记忆检索和 RTC 播报顺序沿用既有逻辑。此改动需由服务端部署后才可线上复测，本机未部署。长录音的上传瓶颈独立于连接池优化，目前发送前仍需上传原声。
- 预连基于本地 `android` 的 `d980558` 与共同基线 `c67693a`。客户端 `7547751` 修改 `lib/rtc_reply_player.dart`、聊天页与用户偏好，sidecar `9ebe016` 修改 `server/rtc_playback.py` 及相关测试。进入聊天页时仅在已授权且开启自动播报的情况下预连。接收令牌无发布音频的权限，播放器也关闭发布音频和视频。切换标签立即静音，空闲连接保留 10 秒；退后台、退出账号、切换书稿、关播报或撤回授权立即释放。正在播报时被打断的房间不会用于下一段，避免迟到回调影响下一条回复。已有音色或租约变化会重新建房。
- Sidecar 为安卓提供 `POST /api/rtc/warm`，逐条通过请求 ID 校验书稿和语音正文，播完用 `/finish` 释放本条回复的占用。三间预连上限为按需播报保留容量，空闲预连不会拒绝另一设备的旧版播报。旧版 sidecar 缺少预连路由时，APK 回退到原有按条建房接口。变更不调整模型、提示词、记忆检索，播报文字及音色沿用原逻辑。
- 2026-11-18 签名一致的 ARM64 Release v8 已构建并覆盖安装。API 36 模拟器使用独立访客及虚构内容，通过现网单条播报兼容测试夹具实际预连、在宽限期内重新进入并复用同一房间、收到 RTC 音频、在离开约 10 秒后释放。系统记录了 RTC AudioTrack 输出，亦有 SDK 二进制消息的参数数量提示，本次播报及释放均完成。静态检查与 43 项 Flutter 测试通过。本地 25 项后端测试覆盖同房间两条消息、账号/书稿隔离、重复请求和旧客户端兼容。生产 sidecar 未部署，完整的新版端到端首段出声测速与 iOS 冒烟待验证。
