# 排除隐藏内容引起的重复扫描 · 2026-10-30

**完成能力**：继续以两个约 1,000 / 10,000 文件的真实授权测试来源排查。双来源同时持续修改普通文件时，原生事件均正常投递，未重现 fseventsd 持续占满单核；但发现只修改既有隐藏日志也会触发整个来源重扫，而这些文件本来就不进入索引。FolderWatcher 现在忽略授权根目录之下、路径含点号前缀组件的普通文件事件。明确授权的隐藏根目录不被排除；更名、硬链接、丢失事件及未知标志仍触发扫描，避免遗漏可见资料变化。复用现有扫描和合并流程，没有增加服务、轮询或数据层。

**用户操作路径**：修复前后分别在两个来源中，每约 0.2 秒修改一份既有 `.activity.log`，持续 30 秒，观察 40 秒。原生观察器每轮均收到每来源 101 个事件，没有丢失事件标志。修复前来源扫描时间改变，修复后两来源扫描时间均未改变，隐藏文件始终不进入列表。随后在两来源各新增一份普通 TXT，不点刷新、不改搜索条件，真实 Release 窗口自动显示两条结果，两来源无扫描错误。普通文件连续写入的另一次 80 秒观察中，fseventsd 平均约 5.35%，没有出现此前持续接近 100% 的状态；这不是永久不复发保证。

| 同一隐藏日志工作负载 | 修复前 | 修复后 |
|---|---:|---:|
| 每来源收到的原生事件 | 101 | 101 |
| 应用平均 CPU，单核 100% | 94.86% | 0.48% |
| fseventsd 平均 CPU | 1.92% | 1.37% |
| 应用数据目录的原生事件 | 697 | 0 |
| 来源扫描时间保持不变 | 否 | 是 |

CPU 根据每秒采样的累计 CPU 时间差计算；其它应用没有完全隔离。事件相同而扫描时间不再变化，是修复无效重扫的直接证据，不能把不同时窗的数字推广为整机性能保证。此修复减少应用自身无效工作，不等于修复 macOS 服务。

**构建/测试证据**：新增真实 FSEvents 回归在旧实现上因扫描时间改变而失败；修复后通过。另两项测试确认明确授权的隐藏根目录仍自动更新、文件更名为隐藏文件后旧记录保留不可用，以及通过隐藏硬链接原地修改可见文件后元数据仍更新。完整 **82 项测试、0 失败**，40.850 秒，无排除项。测试后 Debug / Release 普通构建均成功，运行 Release 的 App Sandbox 开启。原始日志、xcresult、统计和真实截图只保留本机 `.build/FSEvents-Hidden/`，持续双来源观察保留 `.build/FSEvents-Sustained/`，不上传机器路径或原始诊断资料。最终截图为 `gui/02-visible-after-hidden-writes.png`。

```sh
xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages -skipPackageUpdates \
  -resultBundlePath .build/FSEvents-Hidden/full-after-filter-final.xcresult test
# 同参数分别执行 Debug / Release build；日志存于该本机目录。
```

**剩余问题和下一个能力**：历史 fseventsd 高 CPU 的具体事件生产者和系统内部成因仍未确定；已有历史报告早于 PersonalSpace 监听实现，本次有限负载没有复现同等异常。若系统再次停止及时投递，自动刷新仍可能延迟，手动刷新及启动补扫保留。没有修改用户原件、授权范围、对象/事务关联或托管副本。完成本轮排查后停止，不进入 M11。
