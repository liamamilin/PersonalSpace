# M8.1 · 提醒恢复和草稿编辑文案

版本 0.8.1 (10)。只增加用户主动触发的单行动恢复入口；沿用 ReminderController.apply、现有 SQLite 和编辑流程。

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates -resultBundlePath evidence/M8.1-tests.xcresult test
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Release -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ONLY_ACTIVE_ARCH=YES build
```

构建成功，65 项测试零失败。新增测试覆盖状态、日期确认、未来时间和实际待发送 ID 的恢复资格；恢复拒绝路径不改变任何行动数据。原多行动回归通过。

真实 Mac GUI：

- 通过旧版原生界面创建合成 A、B 两条未来行动，替换本地 ad hoc 构建后系统请求缺失，M8.1 显示恢复按钮。过去时间、已完成和已取消行动没有该按钮。
- 在系统设置暂时关闭 PersonalSpace 通知，点击 A 恢复；明确显示「行动已保存，但系统通知未开启」，无成功提示。随后恢复原先开启的通知设置。
- 先恢复 B，再恢复 A；每次均从 UNUserNotificationCenter 重新读取系统实际请求，A、B 均有独立待发送时间，B 在恢复 A 时保持不变。
- 只读核对 actions-before-recovery.json 和 actions-after-recovery.json，全部字段逐行完全一致，包含稳定 ID、日期、状态与更新时间。
- 父事务中的子行动显示「完成行动编辑」与「修改将在保存事务后生效」。完成子编辑后，SQLite 仍无新标题；取消父事务后原行动与两条请求保留。
- 再次修改子行动并保存父事务，标题立即持久化；详情直接编辑保留「保存行动」且没有草稿提示，保存后立即生效，日期与另一条提醒保持不变。

本机截图：missing-requests.png、notifications-denied.png、b-pending-before-a.png、a-restored-b-unchanged.png、finish-draft-edit-label.png、direct-action-save-label.png。截图和原始日志仅留本机；公共仓库仅含合成行动数据与脱敏记录。
