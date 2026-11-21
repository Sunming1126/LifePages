# 隐藏主题访谈 v2 实施与验收交接

## 工作区与边界

- 基线：`origin/android` 的 `e9e3ffd5bf01d3e726297ba4e35959e28750b1b4`；开发分支 `ios/interview-theme-v2`。
- 实施目录：`/Users/zhaoqing/.codex/worktrees/lifepages-interview-v2/LifePages`。2026-11-21 已把共享客户端合回实际编译目录 `/Users/zhaoqing/myprojects/LifePages`，保留其未提交账号、会员和启动优化。没有覆盖原目录后端、原生工程或依赖。详见 [客户端同步记录](CLIENT_SYNC_INTERVIEW_V2_20261121.md)。
- 变更范围：共享访谈后端、书籍版本协商、Flutter 聊天/新建书页面、题库文档与隔离测试。没有修改 iOS/Android 原生源码、签名或依赖版本。
- 没有推送或合并 PR；后续已获用户明确授权，使用本机已有 iPhone 17 模拟器完成文字访谈验收，详见 [追问修复记录](FOLLOWUP_FIX_20261121.md)。后端已于北京时间 2026-11-21 部署，见 [发布记录](DEPLOYMENT_INTERVIEW_V2_20261121.md)。

## 已实现行为

- 30 个隐藏主题、120 道中文原创精选题，偏向成长、学习和事业；每题六项具体验收目标、线索反例、深化方向和不适用说明。完整内容见 [题库与验收细则](INTERVIEW_V2_CURRICULUM.md)。
- 每本书独立打乱各主题四题的顺序，创建时保存；题目出现记录、实际回答、关闭、刷新替换和已覆盖状态均保留。
- AI 根据实际原话生成追问。当前故事没有继续挖掘价值时换同主题新题；四题耗尽后生成新入口，不循环旧题。
- 用户不必严格回答刚问的题面：按同主题里最贴合实际故事的一题验收，避免完整故事被不相关的角度卡住。
- 主题有效原话至少 301 字，加上充分的故事证据与两个主题核心条件，当前故事收束后才能正常完成。300 字不通过；仅字数多也不通过；有新情节继续听。
- 控制语句、同句重复、无来源引用不能凑字数；撤回证据后重算字数和成章资格，保留原始消息与撤回记录。
- 只刷新最新未回答的 AI 问题，直接换另一精选题；素材保留。请求幂等、失败不消耗题目，并发修订冲突后客户端重新加载服务端进度。
- v2 不显示主题/题号；左上角“下一章节”用于提前跳过，旁边圆环表示字数与素材质量进度，点击查看具体字数。达到 301 字但质量不足不显示满环；达标且故事收束后仍自动推进。未达标提前离开保留待补状态；按后续确认，提前进入下一章节时有效原话满 30 字也后台整理短章，少于 30 字只保留素材，正常推进仍为 301 字加质量；气泡刷新继续切换同主题入口。详见 [章节导航与编辑页记录](CHAPTER_NAVIGATION_20261121.md)。
- 按补充要求，聊天页各模式统一隐藏章节副标题和目录切换入口；书名、已有对话和草稿保留。正在运行的旧 App 需要用户从本工作区重新构建启动才能更新界面。
- 一个达标主题形成一章，标题从真实故事细节提炼；支持同章多题素材、后续追加、原声及二维码分享关联。

## 版本、接口与数据

- `GET /api/books` 新增 `interview_versions: [1, 2]`；每本书的 `interview_version` 读取自己的固定版本。
- 新客户端新建访谈书发送 `interview: true, interview_version: 2`。旧客户端不发送新字段时仍创建 v1；旧书没有新版本记录也按 v1。不能通过复用创建请求升级旧书。
- 书籍创建时固定版本并初始化随机顺序；不是修改全局 `CURRENT_VERSION` 来升级所有书。
- 新接口：`POST /api/books/{bid}/interview/messages/{mid}/refresh`，请求为 `text`、`revision`、32 位十六进制 `request_id`；响应为 `id`、`text`、`interview`。过期修订或历史消息返回 409，相同幂等请求返回原结果。
- v2 进度增加 `version: 2` 和 `refresh_message_id`；保留现有 `question`、`total`、`revision`、`characters`、`minimum_characters`、`can_draft` 字段供协议兼容，v2 界面不展示题号。
- 新增表：`book_interview_versions`、`interview_v2_state`、`interview_v2_refreshes`、`interview_v2_prompts`。沿用原账号、消息、录音、访谈和书稿表，新增表通过外键随书清理，不改旧证据布局。
- 状态变更与助手消息在同一事务提交，模型失败不会消耗题目。刷新与发送共用书籍锁和修订校验。
- 模型以原文片段整数编号选择素材和证据，程序解析回真实原话，避免缩写、重抄或省略号导致素材丢失；兼容有证据的对象/数组结构，不采纳模型编造的编号或明确“不充分”的证据。
- v2 判断/写章使用独立 8192 token 输出预算，额外入口 1024；原调用默认 4096 保持不变。证据格只引用必要短片段，全文素材另存。
- 对已核实的 Ark `deepseek-v4.1-flash` / `deepseek-v4.1-flash-economy`，仅 v2 调用明确传入 `thinking: {type: disabled}` 和 JSON 模式，避免默认思考占用共享输出预算。旧流程不传该开关，未知提供方或型号也不附加这两个参数。[Ark 深度思考说明](https://docs.volcengine.com/docs/ark/deep-thinking?lang=en)、[套餐型号说明](https://console.volcengine.com/ark/region%3Acn-beijing/docs/coding-plan-personal-plan-overview)。
- 线上已声明 v2 能力。使用本次客户端新建书即可启用；没有迁移、删除或改写现有书稿。

## 已完成检查

截至 2026-11-21，以下检查在本机或独立临时数据中完成。原项目同步后的完整 Flutter 测试另为 52 项通过（含原目录的首屏预加载回归）；详见 [客户端同步记录](CLIENT_SYNC_INTERVIEW_V2_20261121.md)：

| 检查 | 结果 |
|---|---|
| Python 全量后端测试 | 源码分支 86 项通过，包含后续追问与避重回归 |
| Flutter 静态检查 | `flutter analyze --no-pub` 无问题 |
| Flutter 全套测试 | 51 项通过，包含目录隐藏、旧对话和草稿保留的回归 |
| 新增 iOS 组件测试 | 4 项通过，覆盖隐藏题号、刷新、网络重试、跨设备冲突、新建书版本 |
| iOS 构建 | `flutter build ios --simulator --debug --no-codesign --no-pub` 通过；只编译，未启动设备 |
| 原声与分享 | 同主题多题合章后，分享页提问正确，下载 WAV 与上传字节一致 |
| 题库文档 | 30 主题/120 题/每题六项，生成文档与源码一致 |
| 差异格式 | `git diff --check` 通过 |

真实模型使用已有模型配置、虚构的石桥镇送豆腐故事和临时 ASGI 数据库；未调用生产业务 API、未读取真实书稿。

- 多轮实测：短回答保留为线索，两次记不清后更换同主题入口；完整故事按实际内容验收，进入下一个主题，并生成一章。最终关闭默认思考后的完整多轮访谈与成章再次通过。
- 最终虚构对话与判断记录：`artifacts/interview-v2-live-ark-fixed.json`；更早的一次语义匹配验证生成《桥头垫石》，正文 423 字，见 `artifacts/interview-v2-live-story-aligned.json`（均为忽略文件）。
- 曾出现长故事 JSON 输出截断，最终通过压缩证据引用、v2 独立输出预算及支持型号的显式思考控制修正；还修复了只按当前随机题面验收、误卡住另一段完整故事的问题。失败记录保留在忽略的 `artifacts/`，未自动重试生产任务。
- iOS 构建复用了原目录已存在且被 Git 忽略的 `GoogleService-Info.plist`，未提交配置内容。

可复现命令（在本工作区执行）：

```sh
/opt/anaconda3/bin/python3 -B -m unittest discover -s server
flutter analyze --no-pub
flutter test --no-pub --concurrency=1
flutter build ios --simulator --debug --no-codesign --no-pub
/opt/anaconda3/bin/python3 -B tool/export_interview_curriculum.py
```

真实模型检查会产生模型调用费用，必须提供已有私密配置；脚本不输出密钥：

```sh
/opt/anaconda3/bin/python3 -B tool/smoke_interview_v2.py --config-file /private/path/api_key.txt
```

## 留给用户的 iOS 验收

使用原项目 `/Users/zhaoqing/myprojects/LifePages` 与已发布的配套后端，由用户自行启动 iOS 版。检查真人录音、实际播报听感、刷新时停止旧语音、跨设备续聊，以及成书阅读和 PDF 二维码。没有用编译、组件测试或虚构模型对话代替这些人工体验验收。Android 模拟器/真机验收本次未执行。

待人工查看的重点是：每次追问是否贴合刚讲内容、换入口是否自然、已有故事是否完整保留、章节是否连贯。不能从一次模型样例推断全部 30 个主题都已达到人工访谈质量。
