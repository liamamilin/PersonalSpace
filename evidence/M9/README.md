# M9 · 已授权文件夹自动同步

版本 0.9.0 (11)。复用现有 FolderAccess、FolderScanner、SQLite/GRDB 与资料详情；每个授权来源只有一个原生 FSEvents stream。事件约 1 秒合并后重扫该来源；同一来源扫描期间只记录一次补扫需求，不同来源独立运行。监听持续持有对应的只读 security scope，移除来源立即停止监听，重新授权与重启恢复。

## 实际构建与测试

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates -resultBundlePath evidence/M9-acceptance-tests.xcresult test
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Release -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ONLY_ACTIVE_ARCH=YES build
bash scripts/package_release.sh --skip-build
```

69 项测试零失败。新增四项使用真实目录、真实 security-scoped bookmark 和实际 FSEvents，覆盖元数据更新、移走/恢复、对象/事务/事实及 Vault 保留、双来源连续新增、最终停止重扫、移除来源、无效授权隔离，以及启动并发查询。没有模拟事件或假系统状态。最终小幅移动窄窗口 popover 挂载位置后，又完成 Release 构建和真实 GUI 验证；没有为该可逆 UI 调整新增重复单元测试。

开发期间修复了实际发现的启动竞争：界面查询可能取代启动的发布查询，监听恢复现在直接读取已保存来源，新来源监听也不依赖界面查询何时发布。事件采用交互投递标志 NoDefer。测试允许系统事件分批触发合理补扫，再观察最终安静阶段，避免把一次补扫误判为持续扫描风暴。中间失败日志保留本机，最终测试结果为 M9-acceptance-tests.xcresult；最终构建日志为 M9-final-gui-build.log。

## 真实 Mac 操作

2026-10-28 至 10-29，在 macOS 26.6.2 arm64 上使用实际沙盒 Release。通过系统选择面板添加 `.build/M9-fixtures/A-1000` 和 `B-10000`，初始分别含 1,000 与 10,000 个合成 TXT。应用不会自动导入测试来源。

| 验收 | 实际结果 |
|---|---|
| Finder 复制 PDF 到 A，不点刷新 | 自动出现，可搜索、真实 PDFKit 预览与 Finder 定位 |
| Finder 更名 | 新名称 `M9-更名后的订单.pdf` 可搜索；旧路径记录保留不可用 |
| 修改合成 PDF | 用脚本在此测试 PDF 尾部追加注释，大小从 763 变为 818 字节，选中详情和修改日期自动更新，PDF 仍可预览 |
| 关联对象并保存托管副本 | 通过原生界面关联既有「我的电脑」，Vault 校验成功 |
| Finder 移到来源外的 holding | 原记录自动不可用、原件操作禁用；托管副本继续预览、关联保留 |
| Finder 放回原路径 | 自动恢复原记录，同一 ID，原件可访问 |
| 两来源同时连续新增、修改 | 脚本各创建并追加写入 20 份实际文件，搜索显示全部 40 份；最后变化后观察约 19.07 秒，扫描时间戳没有继续变化 |
| 退出、重启最终 Release | 七个既有来源均恢复监听和启动补扫；来源授权、搜索、对象关联与副本保留 |
| 重新授权 A，再向 A、B 各放一份新文件 | 无手动刷新，两份 `M9-重启及重新授权后.txt` 自动出现 |
| 重启后打开 Vault 副本 | 默认 PDF 应用 WPS 实际打开合成订单，应用内也可切换预览副本 |
| 窄窗口 | 缩至约 788 点宽，列表和搜索可用；溢出菜单「详情」显示原生 popover，实际读取 PDF 内容与对象关联，Escape 可关闭，放大恢复三栏 |

只读 SQLite 核对 before-restart.json / after-restart.json 完全相同：文件 ID、可用性、元数据、对象关联、Vault 路径是否存在及两份 SHA-256 均保留；测试文件没有自动正文索引。SQLite quick_check 返回 ok。11,000 份基础合成文件逐份内容与生成值相同，staging PDF 与仓库夹具哈希一致，见 synthetic-originals-check.json。扫描本身不写原件。

## 规模观测与截图

实际 Release 初扫的首条至末条 indexedAt 差值：A 1,000 份约 0.172 秒，B 10,000 份约 2.325 秒。这是扫描写入阶段，**不包含授权、事件等待和界面发布总耗时**。扫描期间 ⌘F 能接受搜索，完成后可找到 B 的第 9,999 号文件。观测见 initial-scale-observations.json 和 burst-observations.json；没有测量帧率，不把这些数据宣称为完整 GUI 延迟基准。

本机真实截图：scale-search.png、automatic-pdf-preview.png、missing-original-managed-preview.png、two-source-burst-40.png、restarted-source-monitoring.png、automatic-after-restart-and-reauthorization.png、restarted-linked-pdf.png、restarted-managed-copy-default-app.png、final-library.png。窄窗口 popover 的内容由实际辅助功能树核对，见 compact-details-accessibility.txt；截图工具仅截主窗口边界，不宣称已截到边界外的 popover。

截图、完整构建日志、xcresult、应用数据库和发行签名信息仅保留本机，公共仓库只提交代码、合成元数据及本记录。沙盒 Release ZIP 经 codesign 和 ZIP 完整性检查；仍为本地 ad hoc 发行，未做 Developer ID、公证或干净账户验收。浅色外观沿用系统语义色，本轮未切换系统外观重测。完成本轮后停止，不进入 M10。
