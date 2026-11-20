# 0.10.8 (23 / 24)：开源批量扫描适配与复查

2026-11-07，当前开发 Mac。此记录不把已有索引重扫或小样本正确性测试当成百万文件首次建库的耗时证据。

## 完成能力

直接适配 [Oil Find 的 MIT 批量读取实现](https://github.com/oil-oil/oil-find/blob/8f7b9db9e9785eb0a75746fa7f3c66fd47aae6c8/Sources/COilFind/coilfind.c)，固定版本 `8f7b9db9e9785eb0a75746fa7f3c66fd47aae6c8`。`NativeScan/BulkDirectoryReader.c` 解码 macOS `getattrlistbulk` 返回的名称、类型、大小、设备/文件身份、创建及修改时间、隐藏标记。Swift 扫描器按已打开的目录句柄读取和进入子目录，并核对身份；不再对每个普通文件取 Foundation 元数据、解析完整路径。包与目录隐藏属性仍按目录核对。

不支持该接口的磁盘回退至持续的 `readdir` 迭代，跨输出缓冲区保留尚未交付的条目。回退及单文件更新继续检查 Finder 隐藏标记。符号链接不跟随；自身数据库、托管目录和云端未下载目录不进入扫描，其中云端目录作为明确的未读取位置报告。扫描仍不读取正文。

首次入库的新增文件使用每条最多 64 行的 SQL，512 个文件形成一个扫描入库批次；已有记录的 ID、关联、敏感标记和正文失效规则保留。文件类型按扩展名推断，未知或无扩展名登记为通用数据。

构建 24 复查修复：局部更新遇到隐藏、包、符号链接或被普通文件替换的上级路径时，原来直接返回或误报权限错误，旧记录可能仍可用，旧正文甚至仍能命中。现在只核对并失效请求范围的旧记录，不进入被跳过的路径，也不影响范围以外的资料。批量属性缺少 Finder 信息时继续补查隐藏状态。

同时阅读了 [Syncthing walker](https://github.com/syncthing/syncthing/blob/main/lib/scanner/walk.go) 和 [FSearch scanner](https://github.com/cboxdoerfer/fsearch/blob/master/src/fsearch_database_scan.c) 的扫描实现，作为设计参考；本轮直接引入的代码来自上述 MIT 实现。许可证见根目录 `THIRD_PARTY_NOTICES.md`，已加入应用资源及打包完整性检查。

## 用户操作路径

生成 0.10.8 (23) 的本地 Release ZIP，默认使用用户已指定的 AI Desktop Assistant 证书。扫描入口仍是「添加文件夹」或「设置 → 来源 → 刷新」。本轮没有替换或重新启动 `/Users/milin/Applications/PersonalSpace.app`，没有操作生产资料库或重新触发真实来源扫描。

复查后以 0.10.8 (24) 包替代构建 23；仍只生成本地包，没有替换运行中的安装版或启动真实来源扫描。

## 构建/测试证据

`.build/OpenSource-Scanner/debug-build-final.log` 为普通 Debug 构建；`.build/OpenSource-Scanner/package.log` 为 Release 构建和打包记录。C 源通过 `clang -fsyntax-only -Wall -Wextra`，`git diff --check` 通过。

`.build/OpenSource-Scanner/final-tests.xcresult`：110 项隔离回归、0 失败。最后调整回退迭代的待交付条目保存方式后，`.build/OpenSource-Scanner/native-final-tests.xcresult` 再次运行全部 18 项受影响的 LibraryTests、0 失败。新增检查包括跨批量元数据及 SQL 边界无遗漏、中文与组合字符路径、日期/大小/类型、原 ID 保留、BSD/Finder 隐藏属性、回退模式的包和符号链接、正文/关联/敏感标记保留。正确性用例约一千个空文件，用于跨越内部缓冲区，不记录或宣称性能结论。

XCTest 宿主改为内存资料库，窗口恢复不会打开真实活动资料库；测试用例继续各自使用独立临时目录/数据库。未为此轮性能核验重新扫描 `milin`。

构建 24 的新增用例覆盖隐藏/包/符号链接/普通文件替换/路径消失五种情况。修复前 `.build/Scanner-Review/before.xcresult` 记录该用例 8 处断言失败；修复后 `.build/Scanner-Review/after.xcresult` 的全部 111 项回归通过。C 的 `clang --analyze -Wall -Wextra` 无诊断。回归中发现启动监听用例仍有数据库读取时删除临时库的警告，现改为先停止并等待任务，再关闭数据库、清理目录；`.build/Scanner-Review/cleanup.xcresult` 的对应回归通过且无该警告。这是隔离用例的清理顺序问题，不涉及生产数据库。复查后的构建和打包日志位于 `.build/Scanner-Review/debug-build.log` 与 `package.log`。

## 剩余问题和下一个能力

遵照用户「不要补测」要求，未运行真实大目录、百万文件首次建库或冷缓存性能补测。故本轮可交付结论是批量遍历及首次批量入库已经落地并通过正确性检查，不能宣称真实大目录首次扫描已在某个时限完成。新版本的真实 GUI 扫描耗时未验证。系统受保护目录的授权仍由 macOS 决定；不能用修改代码绕过授权等待。
