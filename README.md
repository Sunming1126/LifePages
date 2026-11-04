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
