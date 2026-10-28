# M4 实际验证 · 2026-10-28

完成能力：订单、合同、保修、订阅共用事务/事实/行动；类型与状态筛选；PDF/图片/TXT/Markdown 按需提取；用户明确允许的 FTS5 正文检索；可选本机 Foundation Models 结构化候选。未知日期不推算，正文默认不保存。

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
  -resultBundlePath evidence/M4-tests.xcresult test
```

真实结果：BUILD SUCCEEDED；TEST SUCCEEDED，36 tests / 0 failures。新增覆盖真实 M3→M4 两条记录升级、四种事务持久化、真实 FTS MATCH、中文短词、特殊引号、正文替换/删除触发器、敏感/超限拒绝、纯文本/BOM/日期和模型候选引用校验。系统 trigram 独立探针也已运行成功。测试后再次普通构建，codesign --verify --deep --strict 通过，沙盒授权见 entitlements.txt。

## 真实 GUI

- 原生目录面板添加 fixtures/M4；保留既有 A/B/M3 来源、个人对象、托管副本及订单，共 9 份合成资料。
- 从三份新 PDF 创建合同、保修、订阅，分别提取 7、5、6 项明确候选；保留缺失字段，原文的无关校对日没有变成事实。
- 合同相对方手动修改并确认，合同到期日、保修到期日、订阅下次扣费日逐项确认；分别独立填写未来提醒时间，三条系统请求实际安排成功。
- 合同测试行动标记完成；保修和订阅测试行动取消；没有留下这些未来测试提醒。
- 从保修、订阅事务点凭证，返回正确原件，系统嵌入预览和原始路径相符。合同也由全文命中打开正确 PDF 预览。
- 识别界面实际显示“此 Mac 不支持本机模型”，模型按钮禁用，手动和规则提取完整可用。系统实际 availability=deviceNotEligible；真实模型生成未验证。
- 仅明确保存合同正文。默认名称/路径搜“书面确认”无结果，启用正文搜索命中正确合同。移除索引后命中消失，从详情再次识别保存后恢复；中文两字“续约”实际命中。
- 退出重启，四类事务、确认值、凭证关系仍在；重新启用正文搜索，“续约”继续命中合同。
- 发现并修复筛选后详情保留隐藏事务的问题；重建后选中订阅再筛选合同，详情清空并要求重新选择。正文搜索提示也与启用范围一致。

实际截图仅保留本机 evidence/M4/：01-contract-reminder.png、02-four-types.png、03-full-text-search.png。原始 build/test 日志及 xcresult 同样仅保留本地。

未验证：支持 Apple Intelligence 设备上的真实模型生成、Developer ID、公证与分发。继续 M5 的 PhotoKit 只读关联和敏感状态。
