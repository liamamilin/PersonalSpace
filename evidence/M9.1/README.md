# M9.1 · 全文索引新鲜度

版本 0.9.1 (12)。扫描批次在同一 SQLite 事务中比较大小与修改时间，变化时删除旧 document_text（现有触发器同步删除 FTS5 token），标记需要重新识别。未变化的扫描保留正文与原索引时间。不可用或来源报错时，旧正文不参与长词 FTS 和中文短词匹配；名称/路径与关联仍保留。快速收纳副本沿用原逻辑。升级时也清理修改时间晚于原索引时间的已知旧正文；已确认事实、关联和 Vault 不改动。

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates -only-testing:PersonalSpaceTests/FullTextTests -resultBundlePath evidence/M9.1-fulltext-tests.xcresult test
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace -configuration Release -destination 'platform=macOS' -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ONLY_ACTIVE_ARCH=YES build
```

关键全文测试 9 项全部通过，Release 构建成功。覆盖 M9 升级、日期/大小变化、重复扫描、短/长词、索引替换、过期识别结果拒绝、不可用来源、原有事实/对象/托管关系。两轮全量 71 项运行中，原生 FSEvents 集成测试发生事件等待超时，其余回归通过；未将全量回归标为通过。已避免测试宿主窗口自动扫描用户真实来源，原生事件测试仍需进一步稳定时序。

2026-10-29 真实 Mac GUI：系统面板授权合成目录，选择合成 TXT 并显式保存正文；开启正文搜索，amberorchid 命中。脚本把该测试文件从 105 字节改为 131 字节，未点刷新，实际 M9 扫描后 amberorchid 不再命中，数据库正文行已移除且 textNeedsRefresh=1。按名称仍能找到文件并看到失效提示；点击「重新识别并保存正文」，cobaltmeadow 命中。右键同一来源执行刷新，新词仍命中；前后正文、稳定 ID、元数据和索引时间逐项相同，见 before-repeat-scan.json / after-repeat-scan.json。

真实截图仅保留本机：old-body-match.png、old-body-no-longer-matches.png、new-body-match.png。invalidation.json 是对合成文件的只读数据库核对；不是模拟状态。判断边界是文件实际大小与修改时间，不计算每次扫描的全文件哈希；刻意修改内容却保持这两项完全相同不在本轮保证范围。
