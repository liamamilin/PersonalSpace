# M7 · 快速收纳验收

版本 0.7.0 (7)，基于 main 的 M1–M6 继续实现；macOS 26.6.2 arm64，Xcode 27.1，Swift 6.4。

## 实现

- 「待整理」入口、Finder 文件 URL 单份/多份拖放、文件菜单与系统多选文件面板（⇧⌘I）。
- 复用 ManagedFileStore 的复制和 SHA-256 校验；成功才事务写入同一 SQLite/GRDB。导入父目录不成为来源，不保存原件授权。
- 名称/原路径搜索、系统预览、默认应用打开托管副本、Finder 定位副本、重启保留。
- 复用已有对象和四类事务。待整理表示导入且尚无对象/事务关联；整理后仍保留在所有资料和已托管。
- 不自动 OCR 或保存正文；敏感标记继续生效。目录、包、符号链接拒绝，失败有逐份反馈，不覆盖同名文件。

## 构建和测试

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackageUpdates -resultBundlePath evidence/M7-final-tests.xcresult test
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackageUpdates CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ONLY_ACTIVE_ARCH=YES build
```

最终 56 项测试 0 失败；新增 7 项直接覆盖原件字节/日期不变、托管独立性与重开搜索、同名不覆盖、对象及四类事务关联和待整理筛选、敏感/扫描边界、非法输入、数据库失败回滚、M6 数据升级。Release 真实构建成功，严格签名校验通过，App Sandbox 保持开启，Release 不注入调试权限。结果见 verification.txt、file-verification.json 和 release-verification.json。

## 实际操作记录

- 文件菜单打开 NSOpenPanel，选择 M7-整理说明.txt，真实出现于待整理，Space 预览显示托管 TXT 内容：通过。
- 自动化未能触发跨应用系统拖放；由用户在真实 Finder 手动拖入备好的 PDF、PNG、TXT，并确认三种文件可见。随后读取真实界面核对了三种文件的独立托管记录：通过。
- 系统面板用键盘多选 PNG 和 PDF，一次确认，界面显示「已收纳 2 份文件」：通过。Finder 多选单次拖放未单独确认。
- 导入 PDF 关联已有「我的电脑」，从待整理移出，仍可在所有资料中搜索：通过。
- 导入 PNG 用 Space 显示真实图片，从四类菜单选择创建「M7 收纳设备保修验收」，保存后从待整理移出；事务保留该 PNG 凭证：通过。四类事务的导入凭证关系由直接相关单测覆盖。
- 退出后重新启动 Release，六份导入记录仍可搜索，PDF 系统预览与对象关系保留，保修事务及其 PNG 凭证仍在：通过。六份包含一次菜单单份、三种 Finder 文件、一次面板两份，重复导入各自独立保留。
- 重启后用默认 WPS 应用打开托管 PDF，界面显示合成 PDF，lsof 只读核对实际打开的是对应 Vault 路径：通过。
- 三份原件的 SHA-256、字节数、修改时间与导入前逐一相等；六份托管副本哈希全部匹配，未产生自动正文索引：通过。

## 本机截图

实际截图保留在本机，不上传公共仓库：

- 01-inbox-empty.png：真实待整理空状态。
- 02-menu-import-text-preview.png：文件菜单导入后的 TXT 托管预览。
- 03-finder-imported-files.png：用户真实拖入后的 PDF、PNG、TXT 列表。
- 04-png-managed-preview.png：PNG 的系统放大预览。
- 05-created-matter.png：保修事务及其导入凭证。
- 06-multiple-panel-import.png：系统面板一次收纳两份及 PDF 预览。
- 07-restart-search-linked-preview.png：重启后的搜索、PDF 预览和「我的电脑」关联。
- 08-default-app-managed-pdf.png：默认应用实际打开托管 PDF。

## 剩余限制

仅收纳普通本机文件，不递归导入文件夹，不做文件承诺型拖放、自动去重或内容自动分类。Finder 多选单次拖放未单独确认，真实三种文件单份拖入和系统面板批量均通过。沿用本地 ad hoc Release；Developer ID、公证和干净账户安装不属于 M7，仍未验证。M7 完成后停止，未扩展 M8。
