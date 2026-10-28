# M2 实际验证 · 2026-10-28

完成能力：个人对象创建/编辑、跨来源多对多关联/解绑、资料库与对象互相导航、主动复制并校验托管副本。源文件始终保留；移除来源保留对象关系和托管副本。

## 构建和测试

```bash
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates build
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates \
  -resultBundlePath evidence/M2-tests.xcresult test
```

结果：`BUILD SUCCEEDED`，`TEST SUCCEEDED`，12 tests / 0 failures。包含原有 6 项 M1 回归，以及 M1 带两条真实旧记录升级、对象编辑/跨来源/多对多/重启/解绑、复制字节和 SHA-256/移走原件、失败复制不产生成功元数据、移除来源保留关联和副本、Vault 路径与符号链接边界。

测试后再次普通构建并通过 `codesign --verify --deep --strict`。最终沙盒授权见 `entitlements.txt`，没有 XCTest 的全目录临时读取例外。原始日志 `evidence/M2-build.log`、`evidence/M2-test.log`、`evidence/M2-tests.xcresult` 仅保留本地。

## 真实 GUI 操作

下列截图保留在本机 evidence/M2/，不上传公开仓库。

- `⌘N` 创建「我的电脑」，填写设备类别与合成验收备注，保存成功。
- 「添加已有资料」中通过 `⌘` 多选来自 A 的订单与 B 的发票，关联成功并显示两份资料。见 `01-object-links.png`。
- 点击「保存副本到资料库」，复制校验后出现真实托管状态和独立打开按钮。
- 只移走合成订单原件并刷新：原件按钮禁用，仍显示完整托管 PDF 预览。见 `02-managed-with-missing-original.png`。
- 点击「打开托管副本」，默认 WPS Office 实际打开对应 PDF 窗口。
- `⌘Q` 退出、原件仍缺失时重启，从个人对象进入「我的电脑」，两份关联和托管预览均保留。见 `03-restart-managed.png`。
- 测试原件已放回并刷新，原件入口恢复，托管副本继续可用。

未验证：深色外观仍未手工检查；Developer ID 签名、公证和分发留到发布阶段。未宣称已完成这些验收。M2 已交付，长任务继续进入 M3 的订单文字识别、编辑事实和已确认日期的提醒。
