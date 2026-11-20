# 已授权来源的侧栏移除入口

## 完成能力

侧栏已授权来源的右键菜单增加「移除来源…」。侧栏与设置共用 `SourceRemovalConfirmation`，确认框显示来源名称，说明停止扫描及自动更新、保留已有关系与托管副本、原文件不变，以及重新添加可恢复访问。继续调用现有 `LibraryModel.remove`，没有新增删除原件或清除历史资料的操作。

## 用户操作路径

已安装原版本仍可用 `⌘,` →「来源」→「移除来源」。源码新增路径为右键侧栏来源 →「移除来源…」→ 核对来源名称并确认。此次未点击真实来源的移除确认；验收结束时，真实界面显示无已授权文件夹，只读核对当前库为一个已停用文件夹来源、一个启用的照片来源，保留 1,792,540 条历史资料记录。未擅自重新启用来源。

## 构建/测试证据

- 2026-11-07 20:49 的工作区快照：Debug 构建及两项关键 XCTest 通过，0 失败。`ObjectAndArchiveTests/testRemovingSourceKeepsLinkedMetadataAndArchiveWithoutTouchingOriginal` 验证原件、关联与副本保留及重新添加恢复；`FolderWatchingTests/testBurstAndTwoSourcesSettleAndRemovalStopsOnlyThatSource` 验证移除仅停止指定来源的监听。
- 使用 `PersonalSpace.xcodeproj` / `PersonalSpace` scheme、macOS destination、固定本机证书；日志与 xcresult 在本机 `.build/Source-Removal/verified-test.log`、`verified-tests.xcresult`。普通 Debug 重建在 `build.log` 中成功。
- 使用不同 bundle identifier 的独立界面验收实例，在选择合成测试文件夹后自动化读取超时，未完成新增右键菜单与确认流程的 GUI 验收。真实来源设置已实际截图并显示在本次聊天中，不能视作新增菜单验收通过。
- 之后另一活动聊天修改了扫描器和 C 桥接；当前整合状态的 Release 构建在 `FolderScanner.swift` 的 `Darwin.stat` 调用处编译失败，详见 `.build/Source-Removal/release-build.log`。前述测试结论仅对应更早的成功构建快照，不代表后续扫描器改动已通过。
- 曾尝试更新已安装应用，随后恢复到原始应用包；恢复包通过 `codesign --verify --deep --strict`。本次启动的另外两个构建验收进程已关闭。用户资料库未被替换，未删除或修改源文件。

## 剩余问题和下一个能力

右键入口源码已完成，尚未交付到已安装版，也未完成新增入口的真实界面验收。等并行进行的扫描器修改能构建后，再统一更新并验证右键菜单的取消、确认和移除后列表刷新。当前可用入口仍是设置页。
