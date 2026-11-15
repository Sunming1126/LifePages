# LifePages

Flutter iOS 口述回忆录：像聊天助手一样自由交流，按住麦克风说话，松开发送；系统定期整理回忆录草稿，支持编辑、PDF 导出和二维码回听原声。

## iOS 与 Android 并行开发

`main` 保存当前 iOS 版本和可复用源码。`android` 从同一基线开始，在另一个本地目录开发。两边共享 Flutter 的 `lib/`、`assets/` 和 `test/`，后端在 `server/`。平台代码分别放在 `ios/` 与 `android/`。需要同步时先合并 `main` 到 `android`，再通过 PR 把通用改动合回 `main`。两边修改同一段共享代码时需要处理合并冲突。

仓库包含 iOS 和 Android 工程。Windows 安卓环境、模拟器启动、首轮功能范围及验收记录见 [Android 开发说明](docs/ANDROID_DEVELOPMENT.md)，两端 Codex 遵循根目录 [AGENTS.md](AGENTS.md)。安卓首轮复用邮箱登录、记录与书稿流程，并接入现有 RTC 插件；社交登录、选图、PDF 和会员支付留待后续接入。

新检出的 iOS 工作目录先从 LifePages 的 Firebase 项目下载 `GoogleService-Info.plist` 到 `ios/Runner/`。Android 注册自己的包名后使用单独下载的 `android/app/google-services.json`。这两个本地配置文件、签名私钥、录音、数据库和构建产物由 Git 忽略。

## 目前的部署

后端部署在 OneSay 海外服务器的独立目录 `/opt/lifepages/`，通过 `https://onesay.top/lifepages` 访问。App 内已设置该地址，首次启动时会自动建立设备凭证，不需要填写服务地址或口令。联网失败时显示重试提示。

每台设备首次安装时会建立独立的访客数据空间，凭证存储在 iOS 安全存储中，服务端只保存凭证哈希。首次绑定账号后，在其他设备使用同一登录方式可查看该账号的书稿。

章节生成二维码后，任何持有链接的人都可以播放相关录音。可以在章节中撤销所有回听链接；已导出的二维码也会随之失效。分享链接只保存在生成它的设备上，重装后可以生成新链接，旧链接在撤销前仍有效。

应用和播放页使用 HTTPS。每个账号的数据分开保存，服务器录音与数据库目前未做应用层加密。服务端按 IP 限流，LifePages 路由关闭访问日志。

## 语音和大模型

语音沿用 OneSay 使用的阿里云百炼 `fun-asr-realtime`，录音时使用与 OneSay 相同的 Fun-ASR WebSocket 协议，凭两分钟有效的短时凭证直连百炼。长期 API 密钥由后端持有，App 不包含长期密钥；短时凭证仅在内存中缓存。每次长按最长约 60 秒，松手自动发送；上滑取消。联网或识别失败时，录音保存在设备上，可点击重试。线上文本回复和回忆录整理使用阿里云百炼 `qwen3.7-flash`，通过 `https://dashscope.aliyuncs.com/compatible-mode/v1` 调用。遇到额度限制时，App 显示重试提示，上游提供恢复时间时按北京时间显示。AI 生成的章节需要家人核对和编辑。

服务器的凭证保存在 `/opt/lifepages/shared/lifepages.env`，权限为仅 root 可读；开发机上的 `.env` 同样是私有文件，不能提交或打包。`api_key.txt`、录音和数据目录均被 Git 忽略。

iOS 的 AI 语音回复通过独立的火山 RTC 服务播放。首次点 AI 回复旁的喇叭并同意后，本书的新回复会自动播报。接入说明与服务器记录见 [RTC 播报](docs/RTC_PLAYBACK.md)。

## 日常使用

1. 打开 App 直接聊天，无需先填写资料；首次发送或录音前确认讲述者同意 AI 处理。文字直接输入；长按麦克风说话，松手自动发送，上滑取消。
2. 在“我的”中补充称呼与经历。若原有多个讲述者，可在此查看其他已有回忆录。
3. 每天北京时间 03:00，服务端检查未整理的聊天：至少三条用户消息且合计 100 个非空白字符时，尝试生成待核对草稿。内容不足继续积累；普通闲聊不强行编造故事；处理失败以后重试。也可在“我的”中立即整理。
4. 编辑并保存章节、生成二维码，再阅读或导出 PDF。生成二维码前请取得讲述者同意；未生成二维码的章节不会附带原声入口。

## 服务器维护

服务名为 `lifepages.service`，每日整理使用 `lifepages-drafts.timer` 和 `lifepages-drafts.service`。后端仅监听 `127.0.0.1:8041`，代码位于 `/opt/lifepages/releases/`，`current` 指向当前版本，数据位于 `/opt/lifepages/shared/data/`。OneSay HTTPS 站点新增 `/lifepages/` 路由；聊天改版的原站点配置备份位于 `/etc/nginx/backups/onesay.top.pre-lifepages-20261105-chat-v2`，数据库快照位于 `/opt/lifepages/backups/20261105-chat-v2`。不要覆盖其他项目的路由或服务。操作前应重新检查当前服务及 Nginx 配置，修改后先执行 `nginx -t` 再平滑加载。

iOS 开发团队为 OneSay 使用的 `BNJ65Y2383`，Bundle ID 为 `com.caoyuming.lifePages`，正式签名和上架前需要在 Apple 开发者账号确认标识可用。

## 检查

`flutter analyze` 和 `flutter test` 检查 Flutter 代码；`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest server.test_app server.test_scheduler -v` 检查设备隔离、消息幂等、实时语音协议及自动整理。开发中没有启动模拟器。线上已用临时虚构资料验证自动建档、实时语音中转、大模型对话、成章和原声链接撤销；语音使用静音样本，仅验证接口连通性，并未验证真实语音识别准确度或 iPhone 上的录音、PDF 排版与扫码体验。

## OneSay 语音控件复用

实时文字滚动面板、声纹及动效来自 OneSay 的 main_shell.dart；句子修订拼接复用其 SttTranscriptAssembler。松手后最多等待最终结果 5 秒，超时使用已收到的文字。录音同时保留 WAV，用于原声回听；识别或发送失败可重试。短时凭证接口需要设备鉴权，响应不缓存，不返回长期密钥。短时凭证继承上游密钥权限，部署者应在百炼侧限制该密钥的模型权限和预算。

OneSay 语音接入版本为 `/opt/lifepages/releases/20261105-onesay-voice`。旧服务端中转接口仍保留，兼容上一版 App。静音样本已验证短时凭证签发及直连识别协议；未做真实设备识别准确度或速度测量。

语音问题的本轮修正、组件手势验收和真实说话样本测试记录见 `docs/VOICE_ACCEPTANCE.md`。聊天默认使用输入区内的「长按说话」，点键盘切换到文字，点文字框上方的麦克风切回语音。

聊天首页使用纸色背景和纸张风格气泡，保留 ChatChat 的输入框和 AI 三点思考动画。章节目录先显示本书已加载的数据，再后台更新。未完成的输入从章节目录查看。

在「我的」点击头像或用户名区域可登录，登录后可在此编辑资料。右上角设置页也提供登录和订单入口。「我的」提供会员方案和页面背景。Firebase 和 App Store Connect 的配置见 [账号与会员接入](docs/ACCOUNT_MEMBERSHIP.md)。背景偏好保存在设备上，同时用于聊天、书架和「我的」。书稿预览、正文编辑和 PDF 导出从书架进入。

当前线上服务端版本为 `/opt/lifepages/releases/20261110T060022Z-stream`，支持文字流式回复和 RTC 分段播报。书架上线及线上数据核对见 [书架迁移记录](docs/BOOKS_MIGRATION.md)。长期记忆的设置、后台回填、向量服务与验收步骤见 [长期记忆说明](docs/LONG_TERM_MEMORY.md)。
