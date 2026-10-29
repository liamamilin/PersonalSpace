# fseventsd 高 CPU 追查 · 2026-10-29

**完成能力**：找到系统保存的 CPU 诊断：此前异常进程 PID 544 在 **2026-10-28 08:24–08:27** 已消耗 90 秒 CPU / 170 秒墙钟时间，平均 53%，报告 footprint 为 1641.48 MB。仓库 M1 首次提交为同日 14:35，M9 监听功能首次提交为次日 00:04，因此该系统进程的异常早于 PersonalSpace 的监听实现。报告二进制 UUID 与本机系统版本一致；热点指令对应系统事件表桶链查找和 UID 过滤，可定位到事件处理路径，但不能据此断言内存泄漏、事件表损坏或指认某个其它程序。该时段的详细事件日志已不可取得。当前应用配置有八个互不重叠的文件夹来源，均不包含活动数据库或 Vault；代码检查及真实测试未发现重复注册或扫描自身写入形成的循环。结论是：现有证据指向早已存在的系统服务问题，尚未发现 PersonalSpace 触发或加重它的证据，不能排除未覆盖的系统状态。

**用户操作路径**：保留其它应用运行，依次比较 PersonalSpace 已运行、退出、启动补扫约一万一千份资料、两个授权合成来源各新增 20 文件，以及重启三个 XCTest 宿主。所有采样均为同一 fseventsd 进程，未在实验中重启服务、清理事件数据库或停止其它应用。CPU 通过每秒读取累计 CPU 时间计算（单核 100%），并非把瞬间 ps 读数当平均值。每组同时写入只属于本次排查目录的文件，独立原生探针使用与产品一致的事件参数（0.3 秒、NoDefer、FileEvents、WatchRoot；增加 CFTypes 仅用于读取返回路径），不调用 flush、不代替应用刷新、不监控全盘。真实 Release 窗口中 40 份文件自动出现，两来源无扫描警告；测试后再启动 Release，新测试文件继续自动出现。

| 采样时窗 | 时长 | fseventsd 平均 CPU | ps 观测峰值 | 独立事件收到/写入 | 最长原生事件延迟 |
|---|---:|---:|---:|---:|---:|
| 应用退出 | 36.5 秒 | 4.03% | 9.0% | 15/15 | 11.6 ms |
| 应用已运行 | 36.9 秒 | 4.11% | 15.0% | 15/15 | 12.1 ms |
| 启动与补扫 | 36.5 秒 | 5.87% | 10.7% | 15/15 | 12.7 ms |
| 双来源新增 40 文件 | 36.9 秒 | 1.23% | 2.1% | 15/15 | 12.7 ms |
| 三次测试宿主重启 | 105.8 秒 | 1.42% | 3.4% | 49/49 | 13.0 ms |

**构建/测试证据**：`build-for-testing` 和测试后的普通 Debug `build` 成功；四个 `FolderWatchingTests` 各执行三次，三个独立宿主 PID，**12 次执行、0 失败**，原始 12 秒超时保留。三轮分别耗时 19.155 / 19.403 / 19.112 秒。共 109 次独立原生事件全部收到，最长 13.05 ms；这是服务投递延迟，应用还有既有的一秒合并等待及扫描时间。当前服务未观察到持续高 CPU 或内存累积。其它后台活动没有完全隔离，数字用于有限时窗的对照，不构成所有负载下的性能保证。产品代码未修改；本轮没有重跑其它模块的全量测试。原始系统报告、逐秒数据、临时探针和真实截图仅保存在本机 `.build/FSEvents-Investigation/`，不推送含机器或个人信息的原始资料。截图为 `gui/01-burst-40-files.png` 和 `gui/02-after-repeated-tests.png`。

```sh
xcodebuild -xctestrun .build/DerivedData/Build/Products/PersonalSpace_macosx27.0-arm64.xctestrun \
  -destination 'platform=macOS' -only-testing:PersonalSpaceTests/FolderWatchingTests \
  -test-iterations 3 -test-repetition-relaunch-enabled YES \
  -resultBundlePath .build/FSEvents-Investigation/lifecycle-tests.xcresult test-without-building
```

**剩余问题和下一个能力**：尚未确定系统服务内部为何进入此前的高 CPU 状态，以及具体触发事件或客户端；历史报告不足以追到这个层级。若 fseventsd 再次积压，依赖它的自动刷新仍可能延迟，不能承诺永久不再发生。现有手动刷新及启动补扫直接调用 FolderScanner，不需要等待事件（代码路径确认）；本轮未人为冻结全局系统服务来制造故障。再次异常时应先取当前热点调用栈再重启，否则会丢失现场，可由用户在本机执行 `sudo sample "$(pgrep -x fseventsd)" 5 -file /tmp/fseventsd-hot.txt`；取样保留本机，勿直接公开。没有增加后台监控、轮询或恢复调度器，停止于本次排查，不进入 M11。

API 生命周期对照：[Apple FSEvents 文档](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)。
