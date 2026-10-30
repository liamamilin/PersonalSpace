# Trial Readiness · 0.10.1 (14) · 2026-10-30

**结论：Trial Ready，范围为本机当前开发账户中的隔离合成资料库。** 未做独立账户或另一台 Mac 安装验收；当前产物仍为本地 ad hoc 构建，不是已完成 Developer ID 签名、公证的公开发行版本。

**A. 从零开始完成主要操作：通过。** 使用现有空备份建立新的独立资料库，保留原库；由 ZIP 解压后的 Release App 启动，确认空状态、添加只读来源、系统面板批量收纳 PDF/PNG/TXT、搜索、预览和打开。Finder 三文件拖入由用户实际完成并确认，随后读取真实应用，看到「已收纳 3 份文件」及新增结果。正常退出重启后资料与授权保留。没有创建账户、读取私人照片或改变系统权限。

**B. 文件、对象、事务、提醒和备份完整路径：通过。** 订单与发票关联「我的电脑」；从所有资料创建保修会预选该对象，保存后对象可直接找到事务及下一步。无对象、多对象和具体对象页面的创建行为均完成 GUI 验证，详见[上下文修复](OBJECT-CONTEXT.md)。创建订单、保修、确认事实、两条未来行动；实际 UserNotifications 返回两个待发送请求，完成 A 后 B 保留，重启后的待办仍能找回事务与凭证。合成来源新增和修改自动更新；移走发票保留不可用记录与对象关系，放回恢复同一 Item/Source ID；重启后新增文件仍自动出现。原始四份合成文件最终 SHA-256 与基线一致。

导出备份包含 6 份资料、2 个对象、2 个事务、2 条行动、3 份托管凭证。验证与临时预览没有新增正式资料库，关闭后实际临时目录消失。恢复并重启后，Vault PDF 可搜索、预览及默认应用打开；来源明确要求重新授权，选择不同路径后稳定 ID 与关联保留。恢复 B 行动先显示无系统请求，主动重新安排后才显示实际待发送时间；修改事实、新增待补日期 C 后 B 保留。恢复库继续收纳新文件并持久化，随后切回保留的旧库；旧库仍有备份后 Finder 收纳的三份文件，恢复库的新编辑与新副本独立保留。两库 SQLite integrity_check 均为 ok。最后通过界面结束合成测试提醒、切回本轮开始前的原始资料库，未覆盖旧库。

**C. 独立运行及安装状态：本机运行通过，公开分发未完成。** 完整 **84 项测试、0 失败，40.378 秒**；Debug 和 Release 构建成功。使用现有打包脚本检查 ad hoc 签名和 App Sandbox，ZIP 完整性与 SHA-256 校验通过。解压到独立位置启动，已核实实际进程路径来自解压产物，从空库开始的试用流程在该 App 中完成，未依赖 Xcode Run。产物为 arm64，部署目标 macOS 26，本机 macOS 26.6.2；Intel 未验证。本机没有已有独立测试账户或 Developer ID Application 证书。`spctl --assess --type execute --verbose=2` 实际返回 rejected（退出码 3），不能据本机非隔离下载的启动宣称 Gatekeeper 安装通过。未公证、未 stapling、未验证干净账户/其它 Mac，未关闭 Gatekeeper 或移除隔离属性。未发现本轮已测路径的功能阻断问题；本轮停止，不进入 M11。

产物：`PersonalSpace-0.10.1-14-local-arm64-20261030T035514Z.zip`，本机 `.build/releases/`。

SHA-256：`1f4d65ba9d90b0a0a91323053fdcefa570f8067398fd472d8933e4b6845960ca`。

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates \
  -resultBundlePath .build/Trial-Readiness/full-regression.xcresult test
# 测试后使用同样参数执行 Debug build，恢复普通沙盒签名。
scripts/package_release.sh
codesign --verify --deep --strict --verbose=2 <解压后的 PersonalSpace.app>
shasum -a 256 -c <产物名>.zip.sha256
```

原始日志与 xcresult：本机 `.build/Trial-Readiness/` 的 `full-regression.log`、`full-regression.xcresult`、`debug-build.log`、`release-package.log`、`gatekeeper-assessment.txt`。真实截图保留本机本目录 `gui/`，重点为 `01-empty.png`、`04-single-object-preselected.png`、`08-object-related-matter.png`、`09-multiple-object-choice.png`、`15-todo-after-restart.png`、`18-finder-three-files.png`、`20-restored-managed-pdf.png`、`25-restored-matter-edited.png`、`28-returned-old-library.png`。公开仓库只保存脱敏文字及 [verification.json](verification.json)，不上传截图、数据库或机器路径。
