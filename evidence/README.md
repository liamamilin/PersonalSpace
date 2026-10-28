# M1 实际验证 · 2026-10-28

环境：macOS 26.6.2 / arm64，Xcode 27.1（27A9275），Swift 6.4，部署目标 macOS 26.0。工程入口：根目录 `PersonalSpace.xcodeproj` / `PersonalSpace` scheme。

## 构建与测试

实际执行（仓库根目录）：

```bash
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates build

xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates \
  -resultBundlePath evidence/M1-final-tests.xcresult test
```

结果：`BUILD SUCCEEDED`；`TEST SUCCEEDED`，6 tests / 0 failures。测试后再次执行普通 `build`，移除 XCTest 为宿主临时注入的权限，再做沙盒复验。`codesign --verify --deep --strict` 成功；最终授权见 `entitlements.txt`，没有全目录读取临时例外。

必要测试覆盖：两个来源中文搜索/筛选与 SQLite 重开、文件移走和放回时保留同一记录、目录包及符号链接隔离且原件不变、扫描失败不批量标丢失、路径及字面关键词查询/排序/分页、移除来源不删除原件。

原始构建日志 `build.log`、测试日志 `test.log`、`M1-final-tests.xcresult` 保留在本地且不提交 Git。下方截图来自实际应用操作，没有模拟界面或注入演示数据库。GRDB 固定为官方 7.11.1；依赖下载时使用同一固定提交的本地缓存，工程仍引用官方远程包。

## 六步真实操作

| 步骤 | 结果 | 真实证据 |
|---|---|---|
| 1. 首次启动无假数据，可添加文件夹 | 通过 | `01-empty.png` |
| 2. NSOpenPanel 添加 A、B，共三个文件 | 通过 | `05-sources.png`、`08-sandbox-library.png` |
| 3. 搜「订单」、选中、系统预览、Finder 定位原件 | 通过 | `02-order-preview.png`；Finder 实际选中 `fixtures/M1/A/订单样例.pdf` |
| 4. 搜「合同」，来自另一个目录 B | 通过 | `04-contract.png`；默认应用“文本编辑”打开对应原件 |
| 5. ⌘Q 退出后重启，来源、搜索、读取原件仍可用 | 通过 | `06-restart.png`；普通沙盒构建再次复验 |
| 6. 移走测试 PDF 后刷新，保留旧条目并提示不可用 | 通过 | `07-missing.png`；放回后再次刷新可自动恢复预览 |

补充实测：`⌘F`、`⌘,`、空格系统预览、来源 B 筛选、表头大小排序、半屏窄窗口折叠 Inspector 后搜索/独立预览，均可操作。图片原件预览见 `09-image-quicklook.png`，窄窗口见 `10-narrow.png`。

已修复实测问题：相同选中 ID 的文件恢复可用后，详情未更新。详情现在跟随选中记录的实际元数据变化重新加载；已用最终普通构建完成“移走 → 刷新 → 放回 → 刷新”验证，最终界面见 `08-sandbox-library.png`。三个测试文件均已放回原目录。

Finder 截图 `03-finder.png` 仅留本地，避免将系统侧栏中无关的个人标签发布到公共仓库。

## 未验证与下一步

浅色已实测；深色使用系统语义颜色但尚未手工检查。未做 Developer ID 签名、公证或发行打包。本机 Xcode 有 iOS 模拟器组件版本提示，未影响本轮 macOS 构建和测试。

本轮停在 M1。下一步建议 M2：创建「我的电脑」，关联已有资料并主动保存一份托管副本。
