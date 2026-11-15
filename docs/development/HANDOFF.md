# 双端开发交接

这里记录当前任务和下一步。版本历史、已上线状态和历史验收沿用原文档。当前开发验证集中在 [测试矩阵](TEST_MATRIX.md)。[版本记录](../迭代记录.md) · [项目近况](../工作进度.md) · [历史验收](../整批功能验收清单.md)

## 当前任务

| 字段 | 内容 |
|---|---|
| 任务 | 多更新源：内置 GitHub 与 BirdLock 镜像（Cloudflare），用户可排序、添加、删除 |
| 分支与基线 | `codex/update-sources`，基于 `origin/main` 的 `411f6c4`。代码交接 SHA `a0c63d4`，本条记录随后续文档提交更新 |
| 评审与检出 | 向 `cyandee/BirdLock` 的 `main` 提交 PR，从 PR 获取当前 HEAD。复现验证时按测试矩阵检出对应 SHA |
| 分支写入负责人 | 本轮由同一 Codex 会话写入两端代码（与「一个分支只有一端写入」的常规分工不同，已在 PR 说明）。现交出写入权，后续修改先在 PR 确认接手 |
| 已完成 | 共享配置 `SharedResources/Updates/config.json` 增加 `sources` 和 `release_download_prefix`。Mac：`UpdateSources.swift`、`UpdateSourceProbe.swift`、`AppUpdater` 选源与包地址改写、「更新源…」窗口。Windows：C# 更新器 `--source` 逐源回退和包地址路由，Python「更新源…」对话框与偏好。工具：`stage_updater.py` 写入 Info.plist，`verify_bundle.py` 校验，`check_update_source.py` 检查镜像是否符合[合法更新源标准](../自动更新.md#合法更新源标准)。镜像 `https://3rd.0x01.page/birdlock/update-api/` 已上线并通过实测 |
| 技术决策 | 清单和更新包仍由现有 Ed25519 / RSA 签名及 SHA256 保证，更新源只决定从哪里取字节。GitHub 是内置特殊项，清单取仓库 `updates/`，包用清单里的原地址。其他源按 `B/<清单名>` 和 `B/download/<tag>/<文件名>` 映射。Mac 并行探测、按列表顺序取第一个可用源，再交给 Sparkle。Windows 按顺序取第一个验签通过的清单，下载时先用该源再回退其他源，换源时丢弃半截文件 |
| 已知限制 | Mac 的发行说明链接仍指向清单原地址，Sparkle 没有改写入口。Mac 每次检查前要等一次探测，最多多几秒。恶意源只能拒绝提供更新，不能投递未签名内容。1.10.0 及更早客户端仍只用 GitHub |
| 剩余验证 | 实体 Mac 经镜像从旧版升级到测试版本（Sparkle 下载、校验、安装、重启）。实体 Windows x64 经镜像完成增量或完整更新并通过健康检查。两端「更新源…」界面的排序、添加、删除、恢复默认在实机上操作一次。详见测试矩阵「实体设备验收」 |
| 下一步 | 维护者审核 PR。Mac Codex 和 Windows Codex 分别在实体设备做上述验收并回填矩阵。镜像侧需保证清单与 `updates/` 同步（缓存不超过 5 分钟），新 Release 附件上线后用 `scripts/check_update_source.py` 复检 |

## 接力方式

1. **Mac 交出**。从 `origin/main` 的当前提交开任务分支。完成 Mac 实现后，列出 Windows 对应模块、需要保持一致的输入输出、测试素材类型和复测入口。把代码和交接记录提交到任务分支，在 PR 留下交接 SHA，明确让出写入权。
2. **Windows 接手**。先 `git fetch origin`，核对交接 SHA，再按指南检出任务分支。仅验证时可检出该提交进行只读复测。要接续修改时先在 PR 确认接手。若 Mac 同时开发，从交接 SHA 开 Windows 子分支，目标设为任务分支。
3. **Windows 回传**。完成本地修复和验证后，记录被测 SHA、系统、设备、真实素材类型和结果。推送自己的分支，更新交接和测试矩阵。原片、工程、导出和原始诊断文件留在设备上。
4. **合并评审**。集成双方改动后，复跑受影响的检查，核对两端行为和工程兼容性。维护者根据 PR 的 CI 及分别记录的设备验收结果审核合并。发版另行授权。[项目规范](../../AGENTS.md) · [Windows 开发指南](../../windows/README.md)

下一次交接更新「当前任务」表即可。并行任务各自在自己的分支记录，集成时保留仍待执行的事项。用 PR 或提交链接追溯已结束任务。
