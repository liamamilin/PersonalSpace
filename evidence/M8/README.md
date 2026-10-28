# M8 · 多行动事务

版本 0.8.0 (9)，沿用现有 SQLite/GRDB 多行动表和 UserNotifications；无数据库迁移。

## 构建与测试

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates -resultBundlePath evidence/M8-verified-tests.xcresult test
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Release -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ONLY_ACTIVE_ARCH=YES build
```

最终测试：63 项，0 失败。Release BUILD SUCCEEDED；scripts/package_release.sh --skip-build 打包通过，签名核对为 ad hoc，App Sandbox 为 true，无 get-task-allow。包括多行动独立保存、A 改期与完成保留 B、第三条补日期、元数据编辑不改行动、重开数据保留、重复或跨事务 ID 原子拒绝，以及原有 M1–M7.1 回归。

## 实机操作（合成素材）

- 从已有合成 PDF 创建「我的电脑」，人工填写合成 MacBook Pro，保存三条行动：检查退货、检查保修、检查 AppleCare。
- A 22:03、B 22:04 两条「系统待发送」由 UNUserNotificationCenter.pendingNotificationRequests 的真实 trigger.nextTriggerDate 读取；C 待补日期，没有推断时间。
- 单独把 A 改到 22:05，B 系统时间仍 22:04；完成 A 后 B 仍待发送。
- 给 C 补充 21:12，独立安排，B 仍 22:04。
- 修改商品事实、备注并添加「电脑发票.txt」为第二份凭证后，三条 action 数据库整行与 before-metadata-edit.json 完全相同。B 与 initial-actions.json 整行相同，包含 createdAt、updatedAt。
- 同一最终构建退出重开后，实际系统请求仍为 B 22:05、C 21:13，A 完成且没有待发送请求。待办显示事务归属。
- 从待办右键取消 B，B 变为已取消且无待发送请求；C 的系统请求仍在。
- 原 M3「测试耳机订单」单行动读取、标题编辑保存通过；ID、归属、行动日期、提醒时间、状态、确认标记与创建时间保持不变（legacy-before/after.json）。
- 修复实机发现的旧操作提示残留：只改行动标题会显示「行动已保存，原提醒保持不变」，不沿用其它行动的取消提示。补充针对性回归。
- 最终提示修正版再次正常重启：C 21:16 系统请求保留，A 已完成、B 已取消且均无待发送请求；旧单行动改名反馈已现场核对正确。
- 用户提供真实通知中心截图，显示 PersonalSpace 提醒已送达（notification-center-user.png）。用户点击此通知后提供应用截图（notification-click-user.png）：事务表选中「我的电脑」，右侧已滚动到「检查 AppleCare」并以蓝色背景高亮，提醒时间为 21:16；B 已取消、A 已完成。实际送达、点击打开对应事务和定位具体行动均通过。
- 通知中心的点击由用户操作，最终定位由用户提供的真实截图核对；界面工具同期仍返回旧资料库窗口，因此不宣称该截图由自动化工具拍摄。

本机 PNG 截图、原始构建日志和 xcresult 仅保存在 evidence；不上传公共仓库。发布的 JSON 仅含本轮明确创建的合成验收事务与行动，不含个人来源、书签或照片。

## 本机开发构建限制

更换 ad hoc 构建并在同一 bundle ID 的 Debug 测试宿主与 Release 间切换后，曾读不到先前系统请求。重新用同一最终 Release 安排后，普通退出重启可读到两条真实请求。记录此现象，不把构建替换当普通重启通过，也没有加入自动重新排期或后台恢复系统。正式发行仍需稳定 Developer ID 签名与公证。

截图路径（仅本机）：three-actions-editor.png、two-system-reminders.png、a-changed-b-unchanged.png、a-done-b-pending.png、c-scheduled-b-unchanged.png、restart-system-requests.png、b-cancelled-c-pending.png、legacy-single-edited.png、title-save-feedback-fixed.png、final-restart-pending.png、notification-center-user.png、notification-click-user.png。
