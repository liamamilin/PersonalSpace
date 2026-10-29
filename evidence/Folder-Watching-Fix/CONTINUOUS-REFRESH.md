# 持续变更下的自动刷新 · 2026-10-29

**完成能力**：进一步分析发现并修复了现有自动刷新的一处真实缺陷：每个原生事件都会重新开始一秒的尾随等待，目录持续变化时扫描可能无限延期。保持现有结构，在 LibraryModel 中保留一秒安静期，并将触发截止时间限制在首个已到达事件之后五秒；原来的扫描去重与完成后补扫继续复用。停止或移除来源时同时清理等待起点。该截止时间只限制应用的合并等待，实际文件出现还包含系统投递和扫描耗时，不是端到端五秒保证。没有新增轮询、后台服务、数据库迁移或通用调度器。

**用户操作路径**：真实 Release 使用已有的 A-1000、B-10000 合成来源。A 中的专用日志每约 0.2 秒写入一次，持续 40 秒；两秒后向 A/B 各新增一个验收文件。修复前，约 19.6 秒的真实截图只有 B，A 直到写入停止才更新；修复后，约 13.5 秒的截图中 A/B 均已出现，而写入仍在继续。独立原生观察器在两轮中都收到 A 的 135 个事件和 B 的一个事件，证明系统在投递事件，延期发生于应用合并阶段。修复后的 48 秒时窗中 fseventsd 平均约 1.09%、ps 观测峰值 1.7%，未重现持续高 CPU；未据此宣称跨时窗的 CPU 性能提升。结束后九秒没有继续扫描，两来源无错误；退出重启后，新文件仍自动出现。只操作本次合成文件，原始用户资料未修改。

**构建/测试证据**：新增真实 FSEvents 用例在旧实现上失败（9.210 秒，A 在持续写入时未刷新，B 正常）；修复后该用例约 5.186 秒通过。测试保持写入时间长于断言截止时间，避免等待目录安静后才误通过。完整 **79 项测试、0 失败**，25.609 秒，无排除项。Debug、Release 构建均成功，实际 Release 签名的 App Sandbox 为开启状态。原始日志、xcresult、CPU/事件统计与截图留在本机 `.build/FSEvents-Deep-Dive/`。截图为 `gui/01-before-fix-during-writes.png`、`02-before-fix-after-quiet.png`、`03-after-fix-during-writes.png`、`04-restart.png`，未上传公开 GitHub。

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates \
  -resultBundlePath .build/FSEvents-Deep-Dive/full-after-fix.xcresult test
# 测试后分别执行 Debug / Release build，日志同存本机排查目录。
```

**剩余问题和下一个能力**：继续比对历史报告的同 UUID 系统二进制后，将热点进一步定位到 `com.apple.fseventsd.notify` 的通知消费路径及事件表桶链查找、UID 过滤；现有快照仍无法确定具体事件生产者或证明系统内部的死循环、泄漏、日志损坏。一次独立的只读补扫观测中 A/B 来源事件数均为零，应用数据目录有 153 个有限事件，当前配置未形成扫描原件引发自身变化的循环。本次修复解决的是系统正常投递时应用自身的刷新饥饿，不能修复 macOS 服务本身不投递事件的问题；原系统高 CPU 的具体触发源仍未定位。保留手动刷新与启动补扫，完成本轮即停止，不进入 M11。

后续双来源持续负载又复现并修复了隐藏内容引起的无效重扫，完整 82 项测试及真实普通文件自动刷新通过，见 [隐藏事件排查](HIDDEN-EVENTS.md)。
