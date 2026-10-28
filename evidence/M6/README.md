# M6 · 备份、规模和本地发行

## 完成能力

设置的「备份」页可导出一致性 SQLite 快照、快照引用的 Vault 文件与版本化 SHA-256 清单。完整验证后恢复到应用内全新 UUID 目录，不覆盖当前资料库。恢复窗口只读恢复 Vault，支持搜索、系统预览与默认应用打开。备份不含来源原件和系统照片原图，含明文数据库和用户允许保存的正文。

备份路径拒绝符号链接、越界、重复/额外清单、缺失/篡改文件及无效 SQLite。WAL 测试真实发现快照遗留 -shm，现已在关闭本次新快照连接后清理快照的瞬态文件，并确认无非空 WAL；主库不受影响。

## 真实操作

- ⌘, → 备份 → NSSavePanel 选择 .build 中新的备份目录：通过，导出并校验 2 文件（数据库 + 1 份托管 PDF）。
- 从该目录恢复到全新内部测试库：通过，主资料库未替换，未重排提醒。
- 恢复窗口实际 PDF 系统预览显示合成 TEST-001 订单；点击打开后 WPS 的实际打开文件路径位于恢复 Vault：通过。
- 独立重算备份大小与 SHA-256：通过。快照包含 13 条资料、1 个对象、3 条对象关联、4 类事务等，详见 backup-verification.txt。
- 最终 Release 实测约 744 × 552 点的窄窗口：自动收起右侧栏，工具栏可弹出详情，⌘F 可搜索，空格系统预览正确；放宽后可恢复右侧 Inspector。修复了三栏同时保留时侧栏被挤裁的问题。
- 实际截图本机路径：evidence/M6/01-restored-vault-preview.png、02-compact-window-search.png；截图与备份不上传公共仓库。

## 构建和测试

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates -resultBundlePath evidence/M6-final-tests.xcresult test
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Release -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates 'CODE_SIGN_IDENTITY=-' 'CODE_SIGN_STYLE=Manual' 'ONLY_ACTIVE_ARCH=YES' build
scripts/package_release.sh --skip-build
```

最终 49 项测试 0 失败；BUILD SUCCEEDED；Release 签名严格验证、沙盒/图标验证、ZIP 完整性检查通过。结果分别在本机 evidence/M6-final-test.log、M6-final-tests.xcresult、M6-release-final-build.log、M6-final-package.log。代码提交包含文本证据，日志、结果包和实际截图留本机。

10,000 个合成文件实际调用原生扫描器，首次 2080.054 ms、重扫 2080.420 ms、20 次名称查询中位数 5.114 ms；初扫/重扫/重开计数均 10000，26 份源 SHA-256 抽查不变。CLI 工具 Swift -O 链接 Debug GRDB，不能当作 GUI/Release 性能。原始 benchmark.txt 与脚本可重现。

## 发布边界

版本 0.6.0 (6)，原生生成 AppIcon，本地 arm64 Release ZIP 和校验文件在 .build/releases。最终实际签名权限包含 Sandbox、app-scope bookmarks、user-selected.read-write（仅用于用户选定的备份输出）和 Photos；来源文件夹书签仍强制只读。Release 无 debug get-task-allow。

本机未发现 Developer ID Application 签名身份。Developer ID、公证、DMG、干净账户安装和完整 VoiceOver 朗读验收未做，不宣称正式发行。当前仅支持在独立测试库验证恢复并打开托管凭证，不提供覆盖当前库操作。本机 Foundation Models 不符合设备条件，实际模型生成未验证。
