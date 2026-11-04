# LifePages 开发交接

产品：面向长辈的语音回忆录。MVP：录音、转写、追问、故事编辑、打印PDF和二维码回听。

开发约定见 AGENTS.md。当前实现是本地单用户预览，录音和 SQLite 保存在 data/，不随 Git 上传。AI通过环境变量 `OPENAI_API_KEY`、`OPENAI_BASE_URL`（默认 https://api.openai.com/v1）、`CHAT_MODEL`（默认 gpt-4o-mini）和 `TRANSCRIBE_MODEL`（默认 whisper-1）配置兼容接口；使用前自行确认提供商支持音频转写。没有密钥时可手动录入文字，AI生成不可用。打印PDF使用浏览器打印功能。

二维码默认指向 localhost，只能在运行本机打开；手机扫码需部署到可访问的 HTTPS 服务，并配置 BASE_URL。当前没有身份认证、加密存储及公网权限控制，禁止公网使用。后续需实现身份、授权、跨设备播放及安全存储。
