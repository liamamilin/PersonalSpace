# M7.1 · 收纳文件移除

版本 0.7.1 (8)，沿用现有 SQLite/GRDB、ManagedFileStore 和原生详情/右键菜单。

实现：仅 imported 文件可移除；先检查对象、事务和事实引用，再显示明确的永久移除确认。数据库提交后才删除 Vault 副本，永不访问原位置。关联检查在提交时再次执行。数据库错误保留副本；副本清理失败显示部分完成及手动重试，不产生新的数据库悬空引用。

实际命令：

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates -resultBundlePath evidence/M7.1-tests.xcresult test
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Release -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ONLY_ACTIVE_ARCH=YES build
```

已运行：60 项测试，0 失败，Release BUILD SUCCEEDED。新增 4 项直接验证移除与 FTS 清理、原件字节和修改时间不变、重开持久化、对象/事务/事实引用保护、非 imported 拒绝、数据库失败保留副本、文件清理失败及重试且不触碰符号链接目标。

GUI 验收已完成（本机 Release 0.7.1）：

- 系统面板导入合成「M7.1-移除测试.pdf」，右键菜单显示移除入口；确认框明确说明永久删除应用记录、正文及 Vault 副本，原件不变。用户确认后界面记录消失。
- 只读核对实际沙盒 SQLite：同名记录为 0；原已记录的 Vault 路径不存在。原件仍为 763 字节，SHA-256 与修改时间纳秒值同 source-before.json 完全一致。
- 退出并重新打开应用，搜索 M7.1 返回 0 份资料。
- 从「M7 收纳设备保修验收」打开已关联 PNG，详情移除按钮提示先解除个人对象、事务或事实出处关联，文件和关系仍在。
- 工具在 Finder 选中合成 PDF、PNG、TXT 三项，由用户一次拖入；用户确认并由工具读取真实界面「已收纳 3 份文件」，待整理从 6 增至 9，TXT 托管预览可见。

本机截图（不上传）：remove-confirmation.png、removed-inbox.png、restart-search-empty.png、linked-removal-blocked.png、finder-batch-three.png。

中途一次界面工具连接超时，重开应用后连接恢复；主线程采样未见业务阻塞，不据此宣称修复了应用卡死。

本机原始日志、采样和截图不上传公共仓库。仅发布代码、合成素材及脱敏结果。
