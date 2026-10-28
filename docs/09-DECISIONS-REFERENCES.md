# 09 · 已决定的技术选择与官方参考

## A. 已决定（不在第一轮反复争论）

| 决策 | 选择 | 暂缓事项 |
|---|---|---|
| Mac 应用技术 | SwiftUI + 少量 AppKit | Electron/Tauri/WebView 主界面 |
| 系统目标 | macOS 26+ | 其它系统与手机端 |
| 本地数据库 | GRDB + SQLite，一个权威库 | 同时维护 SwiftData + SQLite 双库 |
| 文件来源 | 用户授权目录、安全作用域 bookmark | Full Disk Access 全盘抓取 |
| 第一轮扫描 | 枚举 + 手动刷新 + 重启补扫 | FSEvents 常驻监控、复杂文件身份体系 |
| 管理行为 | 索引为主，重要文件显式复制托管 | 自动移动、自动去重删除 |
| 文件理解 | PDFKit、Vision，Foundation Models 可选 | 必须联网的模型及默认全盘 OCR |
| 事务提醒 | 已确认日期 + UserNotifications | 通知状态机/通用工作流引擎 |
| 照片 | PhotoKit 授权只读来源 | 扫 Photos Library 包内部文件 |
| 密码 | 敏感文件识别/引用入口 | 密码保险箱、读取 Apple Passwords |
| 发布前备份 | 数据库一致性快照 + 托管文件 | 同步服务、自动云备份 |

## B. Apple 官方参考

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [SwiftUI NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [SwiftUI Table](https://developer.apple.com/documentation/swiftui/table)
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [FileManager](https://developer.apple.com/documentation/foundation/filemanager)
- [Quick Look UI](https://developer.apple.com/documentation/quicklookui)
- [PDFKit](https://developer.apple.com/documentation/pdfkit)
- [Vision](https://developer.apple.com/documentation/vision)
- [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [PhotoKit](https://developer.apple.com/documentation/photokit)
- [UserNotifications](https://developer.apple.com/documentation/usernotifications)
- [Developer ID](https://developer.apple.com/developer-id/)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
- [SQLite FTS5](https://www.sqlite.org/fts5.html)

## C. 需要在本机验证，但不因此卡住 M1 的事

1. Xcode 实际版本、Swift 编译器、macOS SDK、启用的 sandbox entitlements。
2. 安全作用域 bookmark 在当前 macOS 的重启访问行为。
3. SwiftUI Table + Quick Look 的实际焦点/菜单交互；必要时 AppKit 补强。
4. Apple Foundation Models 在设备的实际可用状态及可用的结构化输出 API（M4 才需要）。
5. PhotoKit 权限和照片缩略图行为（M5 才需要）。
6. Developer ID 证书是否存在、能否执行公证（M6 才需要）。

**SDK 差异处理**：以真正可编译的最小代码和当前系统文档为准。发现某 API 不可用时，先替换成可工作的系统方案，不为“兼容所有未来版本”建复杂适配层。

## D. 尚未确定

正式应用名称、图标、商标、Bundle ID、开源许可证、是否进入 Mac App Store。Codex 可使用临时内部名 `PersonalSpace`，但不可擅自公开仓库、购买域名或代用户建立发行账号。
