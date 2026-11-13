# LifePages 长期记忆

「我的 → 记忆簿」在同一设备账号内跨会话共享。条目仍记录原讲述者。旧讲述者设置中如有暂停，会沿用暂停，直到用户在记忆簿重新开启。长期记忆默认开启，可暂停、查看原话和原声、更正、确认或删除。聊天中可以说「记住这个」，或用「记住：……」指定想保存的内容。

SQLite 保存来源、状态、修订版本和关系。后台每两分钟检查新旧会话，每位讲述者每轮最多处理三批，每批最多八条尚未检查的用户消息，优先处理最近的消息。成功后记录进度，出错时退避重试。后台仅把待整理的文字发给 LifePages 已配置的大模型。关系和需核实的条目经人工确认后才进入长期检索。当前关系图支持人物、地点、事件之间的边，以及由两条已确认亲子关系推导孙辈关系。同名人物可在记忆簿更正名称以区分。

Qdrant 检索按账号隔离。载荷中的讲述者用于保留出处。向量由 LifePages 私有的本地嵌入服务生成。聊天结合最近对话、关键词、语义匹配和已确认关系，最多把五条记忆交给现有对话模型。关闭、删除、更正以 SQLite 的当前状态为准。向量服务暂时不可用时仍可按关键词和已确认关系查找。暂停期间的消息会在再次开启后继续整理。

## 服务安装

1. 按 LifePages 独立服务发布流程备份各账户 SQLite 和保存当前版本指针。将更新发布到新的 LifePages 版本目录。保留原有录音目录、服务环境文件和现有回忆录定时器。
2. 将已校验的 Qdrant 可执行文件放在版本目录的 `bin/qdrant`，保留 `deploy/lifepages-qdrant.yaml`。用 `lifepages-qdrant.service` 管理独立实例，端口为 `127.0.0.1:6333`，持久化目录为 `/opt/lifepages/shared/qdrant-data`。新版本继续携带这两个文件。使用 Python 3.10 或更新版本单独建立 `/opt/lifepages/shared/embedding-venv`，安装 `server/requirements-memory.txt`，并预填充 `/opt/lifepages/shared/embedding-cache`。嵌入服务使用本地缓存离线启动。
3. 将 `LIFEPAGES_QDRANT_URL=http://127.0.0.1:6333` 写入 LifePages 自己的服务环境文件。默认嵌入地址为 `http://127.0.0.1:8042`。可用 `LIFEPAGES_QDRANT_COLLECTION` 设置独立 collection，Qdrant 鉴权由服务专用 `qdrant.env` 配置，LifePages 使用对应的 `LIFEPAGES_QDRANT_API_KEY`。并行验收使用独立 collection 和 `LIFEPAGES_MEMORY_NAMESPACE`。如果要重建索引，切换到新的 collection 名称即可让后台从 SQLite 分批重建。
4. 安装并启动 `lifepages-embeddings.service`，用合成文本检查本地 `POST /embed` 返回 512 维向量。切换 LifePages 版本并检查现有接口。安装 `lifepages-memory.service` 和 `lifepages-memory.timer`，启用定时器后逐步回填线上旧聊天。使用一套隔离测试账号验收原文、原声、关系、暂停和删除。日志只记录处理计数。
5. 回滚时先停用新定时器并停止正在执行的 `lifepages-memory.service`，再按备份恢复环境配置并切换 LifePages 版本。如果回退到长期记忆之前的版本，停用新的嵌入和 Qdrant 服务。新增 SQLite 表保留，可在重新发布后继续处理。原生聊天、原声和章节表使用原来的读写路径。

## 本地验收

可将 `LIFEPAGES_DATA` 指向单独的测试目录，调用 `python -m server.memory_worker` 执行单轮检查。后端测试使用临时账号和合成聊天。Qdrant 私有配置为空时，可验证关键词和关系路径。配置本地服务后，可验证语义匹配、账户隔离和向量同步。

书架版按书筛选记忆和相关召回，账号开关仍共用。启用书架的迁移与发布步骤见 [书架上线与旧聊天迁移](BOOKS_MIGRATION.md)。
