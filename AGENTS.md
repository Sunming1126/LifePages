# LifePages 协作约定

- 仓库：https://github.com/Sunming1126/LifePages.git。每次开发前检查工作区并 fetch、同步远端；不得覆盖未提交工作。同步失败时说明原因，不假装同步成功。
- 完成后运行适当检查，更新 AGENT.md 的进度及交接，提交并推送。遇到远端新提交先同步并解决冲突，不强推。
- 不提交录音、数据库、密钥、虚拟环境或个人资料。不要擅自读取其他项目的真实密钥。
- 本项目当前为本地单用户预览，尚无登录和线上访问控制，不能直接用于公网或真实敏感资料。
- 启动：`python -m venv .venv`，安装 `requirements.txt`，运行 `python -m uvicorn app:app --host 127.0.0.1 --port 8000`。
- 保留已有 SQLite 项目、故事及录音，修改数据结构时提供兼容迁移；对话与 AI 调用的当前限制见 AGENT.md。
