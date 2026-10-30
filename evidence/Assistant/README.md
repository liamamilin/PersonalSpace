# 应用级本机 AI 助手 · 0.10.2 (15)

在原生独立窗口中提供对话、模型选择、真实操作记录、新对话和停止。侧栏入口与 `⌥⌘A` 复用同一助手，主资料库窗口不再重复创建。连接本机已有 Ollama，排除云端别名和不支持工具的模型；没有下载模型或新增外部服务。

12 类工具复用现有资料查询、授权扫描、收纳、预览、对象关联、四类事务草稿、独立行动、真实提醒、照片与备份设置。没有数据库迁移。模型候选和建议提醒仍进入原生编辑器确认；敏感读取、移除凭证、恢复资料库沿用原有边界。对话和推理消息仅保留在内存，原文不写日志。

真实 GUI 验收使用当前开发账户的独立合成资料库，未访问私人照片或日常文件。Debug 完成系统面板授权和扫描；Release ZIP 解压产物完成收纳订单 PDF、显示托管预览、读取发票、关联「我的电脑」、创建保修事务、确认三项事实、编辑两条独立行动。系统实际返回两条待发送请求；通过助手完成 A 后，B 的请求及时间仍在。之后取消 B，避免日后发送测试提醒。助手通过系统保存面板导出并校验了数据库与四份托管副本。三份源文件 SHA-256 不变。日常资料库原 ID 已恢复，合成测试库和原始旧库均保留。

小模型实测存在漏项和缺参，复杂请求不能保证一次完整执行；27B 本机模型完成了两条行动编辑、完成/取消和提醒核验。修复包括完整传递工具标识与推理上下文、明确事实字段、显示模型来源和建议提醒、返回实际收纳记录 ID。模型输出以原生编辑器和实际操作记录为准。照片授权、聊天触发的永久移除及恢复启用确认未重新做 GUI 验收；沿用已有实现和回归测试，不把这些路径标为本轮实测通过。

构建与测试命令（完整原始输出留本机）：

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates test
scripts/package_release.sh
```

最终结果见 `verification.json`。原始构建日志、xcresult、界面截图和模型测试记录位于本机 `.build/Assistant/`，未提交 GitHub。当前为本地 ad hoc 版本；没有 Developer ID 签名、公证或独立账户安装验收。
