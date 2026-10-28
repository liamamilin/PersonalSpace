# M3 实际验证 · 2026-10-28

已实现订单事务、凭证关联、可编辑候选/确认事实、按需 PDFKit/Vision 提取、待办与 UserNotifications 本地提醒。SQLite/GRDB 是唯一持久存储；通知不包含凭证正文、路径、订单标题。完整 OCR 原文仅当前编辑会话可见。

## 构建与测试

```bash
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates build
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates \
  -resultBundlePath evidence/M3-final-tests.xcresult test
```

真实结果：BUILD SUCCEEDED；TEST SUCCEEDED，23 tests / 0 failures。新增 7 项订单持久化/迁移/日期/事务回滚测试、3 项真实 PDF 提取/敏感拒读测试，以及 1 项真实 GRDB 查询取消回归，保留 M1–M2 12 项回归。测试后再次普通构建、codesign --verify --deep --strict 通过；最终只读沙盒授权见 entitlements.txt。日志和 xcresult 保留在本机。

## 实际 GUI

- 从原生目录面板添加 fixtures/M3，选择中文订单 PNG，点击识别，得到 5 个正确候选，完整原文可看。
- 商品值实际修改并确认，购买日期确认；签收日缺失保持空白，不相关条款日期未变成事实或提醒。
- 重新识别后两项已确认字段保持不变，实际导入其余 3 项候选。修复了文本框失焦重复提交可能撤销确认的问题，并重新构建实测。
- 保存未确认日期行动为「待补日期」，系统未获授权且无排期；退出重启，订单、事实和凭证仍在。
- 从事务返回资料库，点击打开原件，系统“预览”实际显示 fixtures/M3/订单识别样例.png，窗口 URL 与原件相符。
- 通知首次授权未通过：行动保留，界面显示授权失败，没有显示已安排。系统服务日志记录授权拒绝；用户明确同意后仅启用 PersonalSpace 的通知。
- 已确认提醒实际安排成功，界面通过系统 pending 查询显示已安排；将 18:30 修改为 18:21 后再次安排成功。
- 行动取消后进入「已取消」组，并撤销系统请求；重新启用必须主动点击，编辑终态不会自动恢复待办。

截图仅保留本机 evidence/M3/，不上传公开仓库：01-ocr-candidates.png、02-needs-date.png、03-confirmed-protected.png、04-notification-failure.png、05-open-original.png、06-cancelled.png、07-reminder-scheduled.png、08-final-matter.png。用户提供的通知中心截图包含其它应用信息，不复制进仓库。

系统在 18:29:33 记录真实投递至通知中心；屏幕共享策略抑制横幅。用户展开通知中心并提供实际通知截图，点击后从退出状态打开正确的「测试耳机订单」。通知中心由用户操作，Codex 读取应用验证路由。

冷启动实测发现取消中的查询显示读取失败横幅，已修复：过期或已取消的查询不再报告读取失败。新增回归实际取消 GRDB 读操作，再次加载种子数据成功；23 项测试全通过。最终普通构建再次启动，快速切换搜索和事务/待办后未再出现错误横幅，订单事实完整可读。Developer ID、公证、发行打包未做。
