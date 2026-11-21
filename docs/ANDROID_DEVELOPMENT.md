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

## 2026-11-18 RTC 上线后复核与 v9

- 基线：`android` / `8c4f910`，`origin/main` 为 `c67693a`；fetch 后没有新增提交，merge 返回 Already up to date，工作区开始时干净。共享修复范围仅 `lib/rtc_reply_player.dart` 的 Android 原生释放顺序；iOS 保留既有释放路径，不改依赖或 iOS 原生工程，不部署任何服务。
- 现网 `/api/rtc/warm` 已可用。独立访客、虚构文字在 API 36 ARM64 转译模拟器上，直接使用新接口成功预连，10 秒宽限期内返回复用，连续三轮共用同一房间且各自调用 `/finish`，宽限期后释放。未使用此前把 warm 转发到旧接口的兼容夹具。
- 第一组测试中三轮预连正常，释放后的下一轮未收到语音并报“语音播报未完成”。检查发现 SDK 实例 `destroy()` 丢弃异步销毁 Future，房间销毁也未等待；Android 现等待房间和原生引擎销毁完成后再允许串行队列重建。复测六轮（3 冷、3 热）全部收到真实非静音音频，释放后的两轮冷连接和本地缓存重播均通过。单次失败不足以证明唯一根因，仍应在真机持续观察。SDK 现存二进制消息参数数量警告仍出现，本次未升级或修改 SDK。
- 测速只在本地忽略目录的播放器副本中添加观察器：每 100ms 读取远端音量回调，以音量 >25 作为首个非静音音频；正式 APK 不含观察器或测速入口。实际耳机/扬声器听感、真人录音识别和真机网络不在此测量内。没有读取真实书稿。

| 复测条件（每组 3 条） | 发送→首字，中位数（范围） | 发送→首个非静音 RTC 音频，中位数（范围） | 首段文字→非静音音频，中位数（范围） |
| --- | --- | --- | --- |
| 冷连接 | 3.256s（3.198–3.743） | 5.397s（5.117–5.441） | 1.376s（1.234–1.770） |
| 已预连接 | 1.811s（1.805–3.421） | 5.374s（3.446–5.632） | 1.645s（1.335–3.531） |

- **结论：预连和复用已生效，但这组首声中位数基本持平，不能宣称总延迟稳定降低。** 热连接的一轮首段 TTS 指令确认等待约 2.858s，仍有云端/网络波动。两组顺序执行、会话上下文不同，首轮有其他本机检查并行，不是受控因果实验，也不是延迟 SLA。
- 另一次主机端纯文字（关闭播报、复用 HTTP 客户端）首字为 1.598/1.506/3.273s；不同客户端条件不能混作 Android RTC 指标。附带 2s/6s 静音 WAV 的上传隔离测试首字为 6.731/10.311s，响应头为 4.497/7.836s；仅测上传及回复，不包含识别，也不算真人录音验收。说明 RTC 预连不能消除上传等待。
- 静态检查无问题；25 项后端测试通过（临时数据库、模拟上游）。首次 Flutter 全套测试出现 Windows 临时文件清理占用，单项复跑和随后 43 项串行全套通过；未因此改动业务或放宽断言。
- 正式入口构建命令：`flutter build apk --release --no-pub --target-platform android-arm64 --build-number 9 -t lib/main.dart`。交付路径 `output/LifePages-Android-ARM64-20261118-v9.apk`，61,310,182 字节，SHA256 `d7234c55cc0b9b28256d4e6a330e11a2ae983778ae3f671e84368aa45ef65a6f`。0.1.0 / versionCode 9，API 24 起，ARM64，沿用内部 Android Debug 测试证书，签名校验通过；模拟器覆盖安装成功并确认版本号。
- 本机证据：`artifacts/rtc-20261118-results.json`、`rtc-20261118-device-2.log`、`rtc-20261118-text-latency.jsonl`、`rtc-20261118-upload-latency.jsonl` 及构建/测试日志。构建产物、日志、访客凭证、音频不提交。Android 真机听感、真人转写、真实测试账号登录/跨端同步、iOS 构建及完整冒烟仍待验证；未合并 main。
- 最终修复版本再次运行静态检查及串行 43 项 Flutter 测试，全部通过（`rtc-20261118-analyze-final.log` / `rtc-20261118-tests-final.log`）。正常入口安装后，模拟器曾出现系统查询及画面采集无响应；软件图形模式重启后模拟器又退出。保留数据，最终以 `-gpu host -feature -Vulkan -no-snapshot-load` 启动并重新安装 v9，首页及文字输入入口可正常打开。仅作界面检查，没有向原有书稿发送内容；音频测速使用前述独立访客。不能用此模拟器图形兼容处理代替 Android 真机验收。
- 代码和记录保留为本地未提交修改；尝试建立独立修复提交时，本机 Git 未配置作者身份，因此未修改身份配置、未提交或推送，供后续会话审核同步。当前修复文件为 `lib/rtc_reply_player.dart`，交接文件为本文。

## 2026-11-18 语音消息全链路复核

- `android` / `8c4f910` 加本机 v9 释放顺序修复。API 36 ARM64 转译模拟器通过正常 `FreeChatPage`，用新访客、约 8.81 秒的虚构中文合成语音，实测实时转写、现网流式回复、预连 RTC。夹具只替换麦克风输入并添加时间记录。
- 已授权语音且开启自动播报时，聊天首页在用户操作前调用 `/api/rtc/warm` 并启动房间。两次发语音均使用已连接房间，没有为这两条消息另建冷连接。切换到其他标签约 3 秒返回时复用同一房间；再次切出后约 10.37 秒发出关闭请求，返回时重新预连。在首页停留时会在租约到期前更新房间（当前配置约 150 秒），App 进入后台会立即释放。
- 两次模拟器实测，松手到完整转写为 0.53 / 0.52 秒，松手到发起聊天请求为 0.70 / 0.59 秒，聊天请求到 AI 首字为 10.90 / 21.67 秒，松手到首字为 11.61 / 22.26 秒。首次说话时短时凭证获取发生在录音期间，未成为本轮松手后的瓶颈。
- 第三轮加入响应头和真实非静音回调计时。松手后 0.48 秒转写完成、0.61 秒发出含原声的请求、23.68 秒收到 HTTP 200 响应头、27.54 秒收到 AI 首字、29.94 秒收到首个非静音 RTC 回调（100ms 采样，音量 >25）。从首段可播报文字到首个非静音回调为 2.28 秒；本轮也使用已预连房间。记录见 `artifacts/voice-chain-v9-detailed-metrics.log`。
- 主机到现网交替用同一句虚构提示，有原声和无原声各 2 次。纯文字从发出到响应头为 3.599 / 0.361 秒，到首字为 4.856 / 2.304 秒；随消息提交相同 8.81 秒原声时，响应头为 39.023 / 39.032 秒，首字为 40.681 / 40.779 秒。主机与模拟器链路不可合并统计。主 API 收完包含 Base64 WAV 的 JSON 请求后才读取上下文并生成回复，预连接解决的是后续播报时的建房和入房等待。
- 上线后若要让原声上传不阻塞回复，需要安卓和主聊天 API 配合：按同一请求编号先提交转写文本，持久化待上传原声，先显示 AI 流式回复，再通过独立接口把原声附加到同一消息，失败可重试且不重复发送消息。需覆盖原声回听、跨端同步和成书引用。此轮只测量与记录，工作区业务逻辑仍与 v9 一致。
- 本机日志位于 `artifacts/voice-chain-v9-device.log`、`voice-chain-v9-repeat.log`、`voice-chain-v9-tabs.log` 和 `voice-chain-network.log`。时延只代表这几轮测试，未用真人录音或安卓真机。

## 语音回复优先与 Android 后台上传

- 基线为 `android` / `8c4f910`、共同基线 `c67693a`，包含本地 v9 RTC 释放修复。`android/` 新增系统后台上传任务，`lib/chat_shell.dart`、`lib/main.dart`、`lib/my_page.dart` 接入安卓流程。`server/app.py` 新增转写先行和原声补传接口，`server/book_api.py` 在章节列表中声明 `deferred_voice_upload: true`。iOS 和未启用该能力的服务器继续使用现有请求。RTC 房间预连和切页宽限期沿用 v9。
- `POST /api/people/{book}/voice-turns/stream` 只发已确认的转写文字和原消息载荷哈希，模型与 RTC 分段走现有逻辑。回复提交后，Android JobScheduler 用 `PUT /api/people/{book}/voice-turns/{request}/audio` 发送二进制 WAV。后端复用原消息记录和哈希，不需要数据库迁移。接口按账号、书籍、请求编号校验，重复上传不会生成新回复或录音消息。
- 前台交接给系统前，草稿保留在原发送队列；交接成功后，原声留在应用私有的不可备份目录，后台任务凭证由 Android Keystore 加密。网络及服务临时错误自动退避重试，需处理的失败可从原声回听面板重试。成功上传后才删除系统队列本地原声。新流程首先提交回复，再排低优先级上传任务；录音未转写成功时仍用已有转写回退。Android 系统会根据网络和后台配额调度，手动强制停止应用可能暂停任务到下次打开。
- Mac 上线范围是主聊天 API 的 `server/app.py`、`server/book_api.py` 和回归测试。请根据服务器实际发布版本合并，先在独立实例验证旧客户端和新版安卓，再在上线后用专用访客确认章节能力标记、新流式端点逐段返回、WAV 上传状态 204，以及跨端原声回放和成书分享。检查反向代理没有缓存流式响应，并接受独立的二进制 PUT 请求。Windows 本次仅在隔离本地环境测试，生产部署和真机网络时延仍待验证。
- API 36 模拟器用虚构 PCM、模拟转写和模拟模型，走实际聊天界面、主 API 和 Android JobScheduler。最终一轮从松手到首字 2.13 秒，聊天请求 230 字节。首字之后、Flutter 界面退到系统桌面后，系统上传了 278,444 字节 WAV。首次返回注入的 503 后，系统约 152 秒后主动重传，收到 204。两次录音 SHA256 一致，队列仅在成功后清除。这个时间包含本地测试模型，不能当作线上转写或生成速度。既有 v9 真实现网测量见上一节。
- 上传后从模拟器会话打开「播放原声」，系统 AudioTrack 输出 139,200 帧（16kHz，完整 8.70 秒）。队列调度与回放日志为 `artifacts/voice-upload-local-server-2.log`、`voice-upload-android-final.log`、`voice-upload-playback.log`。模拟器网络的 Android 连通性探测未验证，但端点实际可达，因此 Android 9 起显式要求可联网的连接，由 HTTPS 上传本身校验可达性并决定重试。
- Flutter 静态检查、44 项 Flutter 测试、33 项隔离后端测试均通过。本地发布包 `output/LifePages-Android-ARM64-20261118-v10.apk` 使用 `lib/main.dart`，versionCode 10、API 24 起、ARM64，沿用测试签名。SHA256 `95a421132227eed6c650c816039d12ed80469f3a02771819738c38ba10c42a09`。仅调试版配置允许回环地址，本地测试入口和样本都在 Git 忽略目录。
- Mac 可用 `output/LifePages-v10-main-api.patch` 审核后端三文件差异，应用前检查现网基线。客户端和服务端变更保留在 Windows 本地工作区，未提交或推送。产物和日志不入库。

## 2026-11-18 主聊天 API 上线

- 线上 LifePages 主 API 从 `/opt/lifepages/releases/20261117T131327Z-book-qa` 切换到 `/opt/lifepages/releases/20261118T150914Z-deferred-voice-v10`。在原线上发布的副本中合入 `server/app.py`、`server/book_api.py` 所需改动和一项回归测试，保留现网已有访谈提示词与章节列表实现。部署实际使用的差异留在 `output/LifePages-v10-production.patch`。
- 只切换 `/opt/lifepages/current` 并重启 `lifepages.service`。旧目录仍可原子切回。生产环境配置、数据库结构、Nginx 配置未更改。切换前后的 OneSay 首页和 SayPal 健康接口均为 200；Nginx、RTC、PlotLoom、Duanju、HealthButler、LifePages 检索依赖与 Docker 受检进程/容器保持原状态，Nginx 站点文件哈希相同。
- 候选版在临时数据库通过 9 项聊天测试和新版/旧版语音集成测试。生产自带的 3 项书稿后台测试在原版与候选版的隔离运行中有同样的失败，未计为通过；本次未调整后台书稿逻辑。
- 公网独立访客在新接口收到逐段回复，首字 1.244 秒。回复结束后原声接口从 404 到补传 204，再下载比对 256,044 字节完全一致。同请求重试返回原回复，旧聊天接口连同原声也正常。该首字计时从服务器端向公网 API 发请求起算，不包括手机录音或转写。部署记录见 `artifacts/v10-production-switch.log`。
- API 36 安卓模拟器用 8.81 秒虚构中文录音走现网真实转写、大模型和 RTC。首页在录音前已预连。松手到完整转写 0.471 秒、到发出小请求 0.635 秒、到首字 3.485 秒、到首个非静音 RTC 音频 7.559 秒。AI 回复保存后在松手后 4.399 秒完成原生上传交接，42.556 秒时轮询确认服务端 WAV 的 281,964 字节与本机完全相同。单轮实测，非真机延迟承诺。上文相同采样原声随旧聊天请求时，松手到首字记录为 11.61、22.26、27.54 秒。模拟器最终恢复正常 v10 包，测速入口未交付。计时见 `artifacts/v10-production-android.log`。

## 2026-11-19 单会话访谈上线

- 交付基线为 `android` 的 `8c4f910`，共同基线为 `c67693a`。共享变更覆盖 `lib/`、`server/` 和 `test/`，实现单会话访谈、30 道题的独立过题准则及整书草稿。
- 生产主 API 已切换到 `/opt/lifepages/releases/20261119T151713Z-interview-v11`。回滚版本为 `/opt/lifepages/releases/20261118T150914Z-deferred-voice-v10`。访谈表和索引在账号首次打开新版访谈时创建。切换前后现有网关和其他受检服务正常。
- 公网独立访客用虚构素材通过真实模型自我介绍、追问、过题、跳过、续聊、成书及分享验收，也验证了补传后下载的 WAV 与上传内容一致。隔离候选版通过 13 项访谈及聊天测试。3 项旧书稿后台测试在 v10 和候选版均复现相同失败。
- ARM64 Release 包为 `output/LifePages-Android-ARM64-20261119-v11.apk`，versionCode 11，Android 7.0 起，签名与 v10 一致。SHA-256 为 `6e49bf29ef2afb407c75e059a95e56266e1d64795e64db5cb2c8f6be4df661f6`。新版 iOS、Android 真机及新版 APK 的线上转写和 RTC 实播待验证。

## 2026-11-20 访谈追问与过题验收

- `android` 工作区基于 `8c4f910`，共同基线为 `c67693a`。共享变更覆盖 `lib/chat_shell.dart` 和访谈后端。30 个话题各加一条情节深度准则，字数超过 300 且准则齐全才自动过题。主动下一题保留已讲素材，跳过排除本题素材。当前题的原话证据与最近对话随访谈恢复。
- 57 项后端测试、46 项 Flutter 测试和静态检查通过。用 API 36 安卓模拟器和隔离后端验证了真实模型。两句短答记录 26 字并停在第 1 题，跑题不增加字数，重开续聊恢复进度，补足故事后自动过题。复现并修复了已讲过一起看戏却被重复询问两人做了什么的问题。
- 模拟器用虚构 PCM 验证真实云转写、RTC 播报、原声后台上传与回放、草稿审核保存和原生 PDF 导出。原声回放输出 140,960 帧。3 页 PDF 的第 2 页二维码可解码，下载 WAV 的 PCM 与原样本逐字节一致。生产沿用 v11，iOS 和 Android 真机待验证。
- 补跑前三题的真实模型回归，共 16 轮。童年住处、童年玩伴、长辈的影响短答分别计 26、34、33 字，重复和跑题后字数均保持不变。分别讲到 220、253、247 字时仍留在本题，补足故事后依次自动前进至第 4 题。第二题重开访谈后恢复原题和 34 字。

## 2026-11-20 访谈后端切换与 v13 安卓包

- 生产主 API 已切到 `/opt/lifepages/releases/20261120T131206Z-interview-v12`，上一版 v11 留作回滚。候选版 14 项后端测试通过。公网独立访客用虚构内容复验了 26 字短答、跑题、自动过题、跳过和手动下一题。
- v13 将未完成输入的入口放在右上角设置。AI 数据授权和语音播报各在本机确认一次，也适用于随后新建的书。撤回会使旧的单书授权失效。Flutter 全套 46 项、另加的跨书授权回归和静态检查通过。
- ARM64 Release 包为 `output/LifePages-Android-ARM64-20261120-v13.apk`，versionCode 13，Android 7.0 起，沿用 v11 签名。SHA-256 为 `6c53969b3f4c8fcb007e7e3de52200123ef6185ebafdb51644e7660f42fbc858`。
- v13 安装成功。API 36 模拟器在启动应用后出现 ADB 和界面响应超时，两本书的授权流程通过 Flutter 组件测试，v13 模拟器交互复验待完成。


## 2026-11-22 隐藏主题访谈 v2 安卓同步

- `android` 从 `e9e3ffd` 开始，共同基线为 `origin/main` 的 `c67693a`，已在安卓历史中。同步来源为 `origin/ios/interview-theme-v2` 的 `4fd71377be6e8a1a401bd3fcadb6ff9a26888984`。按依赖顺序应用六个功能提交中的共享 Flutter、后端源码、回归测试和说明文档，无文本冲突。共享同步提交为 `bd549aa`，断流恢复补丁为 `7dd521e`。
- 共享变更包含 30 个隐藏主题及 120 道精选题、按书保存题序、同主题刷新、自动与提前成章、即时编辑入口及章名正文整理。连接超时、传输异常和回复提前结束均提示保留内容及重试，继续使用同一请求编号与原生原声补传。
- `flutter analyze --no-pub` 通过，Flutter 全套 64 项通过，WSL 隔离后端测试 97 项通过。模拟器 ARM64 Debug 和 Profile 构建通过。使用现有后端 `/opt/lifepages/releases/20261121-stream-progress`，本次没有部署、迁移或访问真实书稿，平台原生工程、签名和依赖保持原版本。
- API 36 `LifePages_V13_QA` 模拟器使用独立安卓用户及新建测试访客，仅录入虚构素材。实测文字流式回复、隐藏主题、同主题刷新、进度圆环、94 字提前成章、完整素材自动跳章归零、书架封面直达编辑器、第二章进入目录和手动整理正文。断网触发超时后出现保留和重试提示，联网重试复用原 `request_id`，本地确认的访谈记录只有一条对应原话。
- 虚构 WAV 通过模拟器麦克风输入，应用完成实际录音、云端转写及原声回放。RTC 与原声回放采集的模拟器输出均包含非静音数据，16 kHz PCM 峰值分别为 734 和 1633。RTC SDK 仍记录 `onRoomBinaryMessageReceived` 回调参数数量不匹配，已测场景的实际音频输出正常。主 AVD 曾在应用启动附近出现 ANR 后以 Windows `0xC0000005` 退出，因此交互验收改在独立 QA AVD。真人麦克风、人工听感、Android 真机及 Mac 端 iOS 回归待验收。
- 无成稿书可从书架打开完整编辑器，输入后退出并重开可读到已保存草稿。ARM64 Release 输出为 `output/LifePages-Android-ARM64-20261122-v14.apk`，versionCode 14，API 24 起，沿用本机测试签名并通过签名校验。SHA-256 为 `fbc047b8d6cdad4fc42854b28bd32416c229636851b94f90b02fa1ff7e9ec83e`。同一 Release 包在 QA 模拟器安装成功并启动。
