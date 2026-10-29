# Product Polish · 0.10.1 (14)

2026-10-29，在真实 Mac 的 Release 应用中使用隔离的合成资料库验收。截图、完整日志和 xcresult 仅保留本机；仓库只提交此记录与不含用户数据的 verification.json。

**完成能力**：文件表格去掉空行条纹，常用打开、预览、关联和创建事务在详情首屏，低频信息折叠。空库清楚区分收纳副本与只读来源。对象详情显示相关事务和下一步；事务优先显示已确认日期、待处理行动与真实提醒状态，历史行动按需展开。修复 Quick Look 视图被窗口关闭后复用的实机崩溃，以及 Inspector 跨页、宽窄窗口过渡的问题。

**用户操作路径**：A：系统面板收纳 PDF、系统预览、默认应用打开、关联「我的电脑」、从对象找回凭证通过；Finder 拖入由用户亲手完成并确认，随后实际界面显示新增收纳结果。B：从凭证创建保修，手填确认事实与日期，添加两条行动，查询实际 UserNotifications 待发送时间；完成一条后另一条仍待发送，从待办找回事务与凭证通过。C：导出本次合成资料、验证、临时预览、恢复重启、搜索并打开 Vault PDF、重新授权来源、编辑事务、切回保留旧库均通过。合成原件 SHA-256 不变，最后已切回原始资料库并恢复系统自动外观。

**构建/测试证据**：最终 Debug、Release `xcodebuild build` 均成功，关键回归 74 项通过，含两项新增备份测试：直接验证不生成副本、临时副本可清理且不能清理正式库。两轮完整 78 项运行有 3 个 FolderWatchingTests 事件等待超时（7 个断言），未将全量测试标为成功；真实 Release 授权目录新增文件约 5.7 秒后自动入库。新验证不增加永久预览目录，关闭临时预览后实际目录消失；历史正式目录保留。

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackageUpdates build
# Debug 构建使用同样参数，configuration 改为 Debug。
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackageUpdates -skip-testing:PersonalSpaceTests/FolderWatchingTests \
  -resultBundlePath evidence/Product-Polish/delivery-core-tests.xcresult test
```

本机证据：`final-debug-build.log`、`final-release-build.log`、`delivery-core-test.log`、`regression-test.log`。修改前后对照见 `before/library-inspector.png` 与 `after/library-inspector-comparison.png`、`before/object.png` 与 `after/object-comparison.png`、`before/matter.png` 与 `after/matter-completed.png`、`before/backup.png` 与 `after/backup-comparison.png`。其它真实截图在 `after/`：empty-light、inbox、search、object、multi-action-editor、actions、temporary-preview、restore-confirmation、restored-library、source-reauthorization、source-authorized、restored-matter-edit、switch-confirmation、returned-old-library、library-light、library-dark、narrow-light、narrow-dark。

**剩余问题和下一个能力**：原生 FSEvents 集成测试时序仍需稳定；Photos 本轮只检查未连接/授权提示，未重新访问私人照片。窄窗口原生浮窗已通过可访问性树与打开托管 PDF 验证，工具的窗口截图未包含浮窗像素，未宣称其完整视觉截图通过。临时预览正常关闭/退出清理，强制终止遗留目录交由系统临时目录机制处理；不自动清理旧版本已产生的正式预览目录。保持本地 ad hoc 发行限制，未公证或做干净账户验收。本轮停止，不进入 M11。
