# 文件监听超时修复与回归 · 2026-10-29

**完成能力**：本次复现的超时来自本机 FSEvents 服务异常：`fseventsd` 持续约 100% CPU，独立原生监听程序同样出现约 12–15 秒的事件延迟，扩大至 30 秒也未让所有断言通过。用户重启该服务后，CPU 恢复空闲，原始 12 秒等待下四项监听测试全部通过（19.642 秒）。撤回所有监听实现实验，不改 `FolderWatcher` 或 `LibraryModel`，不延长测试超时、不跳过测试、不以手动扫描替代事件。只加强测试：等待有效来源启动补扫完成后再写新文件，防止启动扫描误通过；超时信息增加实际可用文件数。

**用户操作路径**：真实 Release 应用使用已授权的约 1,000 与 10,000 文件合成来源，全程不点击刷新。验证新文件进入搜索、文件更名、新内容与选中 Inspector 大小/预览更新、移出后不可用、放回后原 ID 恢复；两个来源各快速新增 20 份文件，界面显示 40 条结果，两来源扫描无错误。变更结束后九秒内扫描时间不再变化，既有对象、事务、事实、行动和关联表摘要不变。退出重启后再次在两来源写入新文件，核对监听和授权恢复。一次使用外部 SQLite 轮询的早期验收曾出现扫描警告；停止轮询后，后续自动扫描清除警告。最终以真实界面和扫描结束后的一次性检查验收。

**构建/测试证据**：最终 Debug、Release 构建均成功。完整 78 项测试全部通过，0 失败，执行时间 20.494 秒；没有任何 `skip-testing` 或 `only-testing` 过滤。四项真实监听用例覆盖元数据、移出/放回、托管副本与关系保留、双来源突发及安静期、停止单个来源、错误授权隔离和启动并发查询。日志、xcresult、原生诊断和实际界面截图保存在本机 `.build/Folder-Watching-Fix/`，不推送公开仓库。

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates \
  -resultBundlePath .build/Folder-Watching-Fix/full-suite.xcresult test
# 测试后分别以 -configuration Debug / Release 执行同一工程的 build。
```

截图：`gui/01-auto-added.png`、`02-selected-metadata-updated.png`、`03-moved-out-unavailable.png`、`04-returned-available.png`、`05-two-sources-40-files.png`、`06-restarted-monitoring.png`（均位于上述本机目录）。

**剩余问题和下一个能力**：未定位 macOS 服务内部高 CPU 的成因；本次没有为系统服务异常增加应用轮询或后台服务。当前测试和真实自动刷新回归通过，停止本轮，不进入 M11。

后续高 CPU 因果排查：已找到早于 M1 的系统 CPU 报告，并完成应用启停、真实批量更新与三次测试宿主重启对照，见 [追查记录](INVESTIGATION.md)。
