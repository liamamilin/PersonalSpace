# M10 真实验收记录（2026-10-29）

## 完成能力

备份设置分开导出、验证预览、恢复启用与保留旧库。先校验备份、复制到全新内部目录、清除外部书签并验证可读性和 Vault 哈希，再原子保存下次启动目录选择。当前 SQLite 不热替换，旧目录保持原状。默认 `Library.sqlite` 兼容；恢复库 `library.sqlite` 与 Vault 使用同一目录。通知请求按资料库区分，旧版原库请求标识不变。

## 用户操作路径

使用单独的合成资料库完成原生 GUI 操作；未导出私人图库或生产资料。通过现有备份代码在工作区生成空白备份，以界面恢复启用后创建「我的电脑」，收纳 `M10-订单.pdf`，授权 External-old 的 `M10-外部凭证.txt`，将两份凭证同时关联对象与保修事务。

- 已确认商品与保修日期，创建 A、B 两条未来行动，界面实际查询 UserNotifications 并显示各自待发送时间。
- 从界面导出备份，随后收纳「M10-备份之后新增.txt」。恢复之前的备份并退出重启：原对象、事务、行动 ID/日期/事实/凭证均保留，新增文件不在恢复库。
- 搜索订单，系统预览可读；「打开托管副本」在默认 WPS 打开 `M10-订单.pdf`。恢复 Vault 与原合成 PDF 的字节相同。
- A/B 数据保留但新库均未安排通知。主动重新安排 A 后，仅 A 显示真实系统待发送时间，B 仍没有请求。
- 同路径重新授权后，原 Source ID、Item ID、对象/事务关联不变；原件恢复可用。
- 第二次从同一备份恢复，重新授权到 External-new：Source ID、Item ID、两条对象关联和两条事务凭证关联均保留；当前事务详情直接更新为「原件可用」，无需重新选择事务。
- 切回旧库并重启，备份后新增文件重新出现。最终构建中旧库 A/B 请求重新安排后，进入新恢复库完成 A，再切回旧库：旧库 A/B 两条请求仍在，证明请求互不干扰。验收结束通过界面完成合成测试行动，取消其请求，并切回原始资料库。
- 恢复库中修改已确认商品，新增第三条待补日期行动，单独编辑 B、完成 A；继续收纳新 TXT，并重新导出。二次备份的数据库及所有文件哈希校验成功，含 3 份资料与 3 条行动。

## 构建/测试证据

关键恢复、备份和正文测试 20 项通过。最终全套 76 项测试全部通过（含原生 FSEvents、不同路径授权后当前事务详情自动更新）。初次断言将行动附带的事务名称与旧名称比较，已修正为比较稳定行动字段及更新时间，并验证新事务名称。没有忽略测试失败。此前 M9.1 全套运行中的原生 FSEvents 超时在本次最终全套运行未复现。

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates \
  -resultBundlePath evidence/M10-all-tests.xcresult test
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Release \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates build
```

测试原始日志 `evidence/M10-all-test.log`，结果 `evidence/M10-all-tests.xcresult`；Release 日志 `evidence/M10-final-release-build.log`。构建、签名和系统工具的原始日志留本机。截图留本机同目录：`restore-confirmation.png`、`restored-managed-preview.png`、`source-needs-authorization.png`、`reminder-recovery-A-only.png`、`different-path-restored-links.png`、`old-library-reminders-preserved.png`；仅提交合成数据的 JSON 结果，不发布截图或书签。

## 尚存限制

新电脑实机、干净账户安装未验证；不同目录在当前 Mac 验证。Photos 跨设备标识可能无效，需当前系统权限和本机资源；不下载 iCloud 原图。备份为明文，不包含外部原件。系统提醒只主动重新安排，不自动恢复。当前是本地 ad hoc 签名，尚无 Developer ID 签名和公证。完成 M10 后停止。
