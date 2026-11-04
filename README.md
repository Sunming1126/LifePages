# 拾光册 LifePages

本地单用户回忆录 MVP：网页录音、文字编辑、可配置 AI 转写和追问、草稿整理、浏览器打印 PDF、章节二维码。参见 AGENT.md。

## 启动

```powershell
python -m venv .venv
.\.venv\Scripts\pip install -r requirements.txt
.\.venv\Scripts\python -m uvicorn app:app --host 127.0.0.1 --port 8000
```

打开 http://127.0.0.1:8000 。AI 配置详见 AGENT.md。录音需讲述者同意；数据保存在本机 data/，请自行备份。

本版本仅供本机预览，没有身份认证或公网权限保护。二维码指向本机地址，不能直接供手机跨设备访问。浏览器打印选择“另存为 PDF”。

AI 本地配置：复制 `.env.example` 为 `.env`，填写密钥并重启服务。火山方舟 Coding 模型采用 `deepseek-v4.1-flash`；其约 1M 上下文是模型上限，当前应用只传当前故事文字，采用保守长度保护。语音转写需单独配置兼容服务，不使用该模型直接转写音频。

在左侧添加讲述者，填写资料后 AI 会开始访谈；文字或录音加手工转写可以用于回答。随时选择结束并生成当前访谈的回忆录草稿，核对修改后保存。每位讲述者可以有多次访谈，目前各访谈分别生成草稿。聊天界面暂不提供自动转写。
