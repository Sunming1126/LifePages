# LifePages 的 AI 语音播报

在 iPhone 上点 AI 回复气泡里的喇叭。首次确认讲述者同意后，本书的新回复会自动播报。再次点同一按钮可停止，点旧回复的喇叭可重播。开始录音、切换章节或退到后台时会退出播报房间。播放失败时仍可阅读文字。

在聊天首页点右上角，打开「切换书籍」面板，再点「AI 播报音色」进入二级菜单，可选择 Vivi（默认）、小何、云舟或小天。选择保存在当前设备，下次自动播报和历史重播时生效。每个播报会话在创建时确定音色，逐段播放期间沿用同一发音人和朗读风格。

## SayPal 代码与 LifePages 的接法

| SayPal 发布目录 | 用途 | LifePages 接入 |
| --- | --- | --- |
| `/opt/saypal/voice/current/backend/saypal/rtc_gateway.py` | RTC Token、火山接口签名、房间和语音任务 | `server/rtc_gateway.py` 复用签名和任务协议，给 App 签发只有订阅权限的短时 Token |
| `/opt/saypal/voice/current/backend/saypal/app.py` | RTC 会话接口和陪练入口 | `server/rtc_playback.py` 用 LifePages 设备凭证读取该设备已保存的 AI 回复 |
| `practice_catalog.py` | 课程上下文、角色扮演 | LifePages 聊天后端按原有章节和记忆生成回复 |
| `providers.py`、`protocol.py` | SayPal 独立的 WebSocket 语音链路 | LifePages 的录音和百炼转写继续走自己的链路 |

新版 App 会通过 `/api/people/{id}/turns/stream` 逐段显示百炼返回的文字。已同意自动播报时，App 同时准备接收 RTC 音频，独立后端用 `ExternalTextToSpeech` 按顺序朗读生成的句子。RTC 服务以只读方式读取与设备、书籍和本轮请求匹配的播报片段。正文在生成完成后保存，同一请求重试沿用已有回复。历史回复按消息 ID 重播，旧版 App 仍可使用原整段回复接口。

[火山引擎自定义文本播报文档](https://docs.volcengine.com/docs/real-time-communication/provide-custom-text-for-ai-speech?lang=zh)

## 海外服务器

- 2026-11-09 上线版本为 `/opt/lifepages/rtc/releases/20261109T141651Z-rtc`。独立服务 `lifepages-rtc.service` 监听 `127.0.0.1:8045`，公网入口为 `https://onesay.top/lifepages/api/rtc/`。
- 2026-11-10 流式版本为 `/opt/lifepages/releases/20261110T060022Z-stream` 和 `/opt/lifepages/rtc/releases/20261110T060022Z-stream`。公网测试用三条虚构消息测得首字 1.56–3.14 秒、首个非静音 RTC 音频 3.61–4.46 秒。旧流程对照样本从发送到显示整段文字为 25.71 秒，到收到首声为 31.76 秒。首声通过网页 RTC SDK 实际接收测得，iOS 播报时延仍待设备实测。
- 2026-11-10 音色选择版本为 `/opt/lifepages/rtc/releases/20261110T062111Z-voice-menu`。四款音色均使用 `seed-tts-2.0`，已逐个验证真实 RTC 音频接收和播报完成回调。
- 服务端沿用 SayPal 的火山 RTC 应用。LifePages 的中文播报使用通过实测的 `zh_female_vv_uranus_bigtts` 和 `seed-tts-2.0`。所需配置存于服务端私有文件 `/opt/lifepages/rtc/rtc.env`。2026-11-13 用当前语音资源测试，50 个房间均加入并接受播报指令，10 路收到实际音频。LifePages 因此限制为 10 个房间，每个账号一个。房间由建立它的登录会话控制。 [豆包语音配额说明](https://docs.volcengine.com/docs/doubao-voice/billing-instructions?lang=zh)
- 公共 TTS 默认 50 并发，需要新版「AI 音视频互动方案」应用。当前 RTC 应用调用新版接口返回 `NoPermissionForApp`。接入新应用后，应重新确认现有音色和实际音频并发。 [火山引擎 RTC 并发说明](https://docs.volcengine.com/docs/real-time-communication/feature-faq?lang=zh) · [新版接口迁移说明](https://docs.volcengine.com/docs/real-time-communication/migrate-conversation-ai-to-new-api?lang=zh)
- 发布前后对比了 OneSay 首页、LifePages 鉴权入口和 SayPal 健康接口的状态，以及 LifePages 和 Nginx 的主进程 PID。Nginx 配置仅新增一个 LifePages 专用位置，备份位于 `/opt/lifepages/rtc/onesay.top.before-20261109T141651Z-rtc`。
- 如需撤回，移除 Nginx 中标记为 `LifePages RTC reply playback` 的位置，检查配置并平滑重载，再停用 `lifepages-rtc.service`。

## 验收

2026-11-09 的真实 RTC 测试发现两处配置问题。SayPal 的行尾注释被作为凭证的一部分，导致入房 Token 无效；旧版音色也与默认的双向合成资源不匹配，改走旧版合成时火山返回授权错误。配置脚本现在会剥离行尾注释，并要求部署时显式指定匹配的音色和合成资源。

用隔离数据库中的虚构回复验证了入房、真实非静音音频接收、播报完成回调和退房。HTTPS 鉴权及既有服务入口也单独核对过。

[火山引擎语音合成配置](https://docs.volcengine.com/docs/real-time-communication/configure-tts?lang=zh)

真机打开一本书，发一条文字或语音，点 AI 回复旁的喇叭确认播放，再发一条验证自动播报。试听时开始长按录音，确认播报停止并能正常录音。最后长按已保存的语音消息，确认原声仍可回听。

### iOS 缺少语音组件

如果模拟器日志出现 `MissingPluginException` 和 `com.volcengine.rtc.hybrid_runtime`，检查已安装的 App 是否带有 `volc_engine_rtc.framework` 和 `VolcEngineRTC.framework`。添加原生依赖后，应结束当前运行并重新编译运行一次，让 Flutter 安装包含原生框架的构建。Xcode 使用 `ios/Runner.xcworkspace`。
