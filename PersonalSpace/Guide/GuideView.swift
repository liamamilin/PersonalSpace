import SwiftUI

private enum GuideSection: String, CaseIterable, Identifiable {
    case quickStart, concepts, privacy, shortcuts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quickStart: "快速上手"
        case .concepts: "核心概念"
        case .privacy: "隐私与本地原则"
        case .shortcuts: "常用快捷键"
        }
    }
    var image: String {
        switch self {
        case .quickStart: "checklist"
        case .concepts: "square.grid.2x2"
        case .privacy: "lock.shield"
        case .shortcuts: "keyboard"
        }
    }
}

struct GuideView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: GuideSection = .quickStart

    private var hasData: Bool { !model.sources.isEmpty || model.total > 0 || model.inboxCount > 0 }
    private var hasObject: Bool { !model.objects.isEmpty }
    private var hasMatter: Bool { !model.matters.isEmpty }
    private var completedSteps: Int { [hasData, hasObject, hasMatter].filter(\.self).count }

    var body: some View {
        NavigationSplitView {
            List(GuideSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.image).tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selection {
                    case .quickStart: quickStartContent
                    case .concepts: conceptsContent
                    case .privacy: privacyContent
                    case .shortcuts: shortcutsContent
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(28)
            }
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 640, minHeight: 440)
    }

    private func focusLibraryAndRun(_ action: @escaping () -> Void) {
        openWindow(id: "library")
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    private var quickStartContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("三步开始使用 PersonalSpace").font(.title2.bold())
                Text("当前进度：已完成 \(completedSteps) / 3 步。全部操作都在本机完成，原文件不会被移动或修改。")
                    .foregroundStyle(.secondary)
            }
            Divider()
            stepRow(
                done: hasData,
                number: "1",
                title: "放进第一份资料",
                detail: "把重要发票或合同拖进主窗口保存独立副本，或添加一个存放凭证的文件夹只读索引（添加前会先统计数量）。"
            ) {
                HStack(spacing: 10) {
                    Button("收纳文件…") { focusLibraryAndRun { model.chooseImportFiles() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.storageUnavailable || model.isImporting)
                    Button("添加文件夹…") { focusLibraryAndRun { model.addFolders() } }
                        .disabled(model.storageUnavailable)
                }
            }
            Divider()
            stepRow(
                done: hasObject,
                number: "2",
                title: "创建一个个人对象",
                detail: "按真实事物组织资料，例如「我的电脑」「租房」或「家人档案」，把来自不同位置的凭证关联到一起。"
            ) {
                Button("新建个人对象…") { focusLibraryAndRun { model.createObject() } }
                    .disabled(model.storageUnavailable)
            }
            Divider()
            stepRow(
                done: hasMatter,
                number: "3",
                title: "从凭证建立事务与提醒",
                detail: "为订单、合同、保修或订阅提取关键事实。日期未知可先保存为「待补日期」，确认具体时间后再安排系统提醒。"
            ) {
                Button("新建事务…") { focusLibraryAndRun { model.createMatter(kind: .order) } }
                    .disabled(model.storageUnavailable)
            }
        }
    }

    private func stepRow<Actions: View>(
        done: Bool,
        number: String,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3)
                .foregroundStyle(done ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    if done {
                        Text("已完成").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                actions().padding(.top, 2)
            }
        }
    }

    private var conceptsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("理解核心概念").font(.title2.bold())
                Text("不需要记忆复杂分类，先分清下面四组关系就能顺手使用。")
                    .foregroundStyle(.secondary)
            }
            Divider()
            conceptItem(
                icon: "folder.badge.plus",
                title: "收纳文件 vs 添加文件夹",
                body: "「收纳文件」会把单份或多份重要文件复制到应用内 Vault，生成可独立预览的托管副本，进入「待整理」；「添加文件夹」只建立原位置的只读索引并支持自动更新，建议选择存放凭证的具体目录，而非整个用户主目录。"
            )
            Divider()
            conceptItem(
                icon: "desktopcomputer",
                title: "个人对象 vs 事务与行动",
                body: "「个人对象」代表长期存在的实体（如一台电脑、一套租房），用来汇总所有相关资料；「事务」代表需要跟进的订单、合同、保修或订阅，下挂经过校对的关键事实与多条独立行动提醒。"
            )
            Divider()
            conceptItem(
                icon: "externaldrive.badge.checkmark",
                title: "原件 vs 托管副本",
                body: "普通来源文件默认只读索引，原件被移走后会显示不可用但保留历史关系；对重要发票或保修单点击「保存副本到资料库」后，应用会校验 SHA-256 并保存一份独立副本，原件丢失仍可查看。"
            )
            Divider()
            conceptItem(
                icon: "bubble.left.and.bubble.right",
                title: "可选的本地 AI 助手",
                body: "所有查找、整理、OCR 识别与系统提醒均不依赖 AI。如本机已安装并运行 Ollama 工具调用模型，可按 ⌥⌘A 打开助手用自然语言协助查询、准备事务草稿或操作来源。"
            )
        }
    }

    private var privacyContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("隐私与本地运行原则").font(.title2.bold())
                Text("PersonalSpace 始终开启 macOS App Sandbox，无云账号、无后台上传。")
                    .foregroundStyle(.secondary)
            }
            Divider()
            conceptItem(
                icon: "hand.raised",
                title: "原件只读，绝不擅自移动或删除",
                body: "添加文件夹、解除关联或移除来源都不会改动原位置文件。只有明确通过「快速收纳」导入的托管副本，才支持在解除关联后从应用内移除。"
            )
            Divider()
            conceptItem(
                icon: "doc.text.magnifyingglass",
                title: "正文默认不入库，按需显式允许",
                body: "扫描目录只读取文件名、路径、大小与日期，不读取文件内容。只有在识别单份普通凭证后主动点击「保存正文供全文搜索」，正文才会写入本地 FTS5 索引。"
            )
            Divider()
            conceptItem(
                icon: "exclamationmark.shield",
                title: "敏感文件隔离保护",
                body: "文件名疑似包含密码、恢复码或账号信息的资料会被标为「疑似敏感」，拒绝进入正文识别、全文索引和本地模型。你也可以在详情中随时手动标记为敏感。"
            )
            Divider()
            conceptItem(
                icon: "externaldrive",
                title: "备份与照片边界",
                body: "系统照片仅通过 PhotoKit 只读访问，不下载 iCloud 原片、不导出副本。导出备份包含明文数据库和托管副本（不含外部原件与照片原图），请保存在你信任的位置。"
            )
        }
    }

    private var shortcutsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("常用快捷键").font(.title2.bold())
                Text("覆盖资料库检索、预览、新建与窗口切换的常用操作。")
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                shortcutRow("搜索资料（可从任意窗口唤回主窗口）", keys: "⌘ F")
                shortcutRow("收纳文件到待整理", keys: "⇧ ⌘ I")
                shortcutRow("添加授权文件夹", keys: "⇧ ⌘ O")
                shortcutRow("新建个人对象（在事务/待办页为新建事务）", keys: "⌘ N")
                shortcutRow("直接新建事务", keys: "⇧ ⌘ N")
                Divider()
                shortcutRow("系统预览选中资料（Quick Look）", keys: "Space")
                shortcutRow("使用默认应用打开选中文件", keys: "⌘ O / Return")
                shortcutRow("在 Finder 中定位原件或副本", keys: "⇧ ⌘ R")
                shortcutRow("刷新当前来源或全部来源", keys: "⌘ R")
                Divider()
                shortcutRow("显示或隐藏右侧详情栏", keys: "⌥ ⌘ I")
                shortcutRow("打开本地 AI 助手", keys: "⌥ ⌘ A")
                shortcutRow("打开来源与备份设置", keys: "⌘ ,")
            }
        }
    }

    private func conceptItem(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutRow(_ title: String, keys: String) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Text(keys)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

/// Calm, frameless first-run empty state shown when the library has no sources or items yet.
struct FirstRunWelcomeView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("把散落的个人资料放到一个入口", systemImage: "folder.badge.plus")
                        .font(.title2.bold())
                    Text("全部数据保存在本机，原文件保留在原位置，不自动上传云端。")
                        .foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    welcomeStep(
                        icon: "tray.and.arrow.down",
                        title: "收纳文件，或只读添加文件夹",
                        detail: "拖入重要凭证保存独立副本；添加文件夹时先轻量统计文件数，确认后再建立索引。"
                    )
                    welcomeStep(
                        icon: "desktopcomputer",
                        title: "按个人对象归拢资料",
                        detail: "为设备、房屋或个人档案建立入口，把来自不同位置的发票、合同与照片关联在一起。"
                    )
                    welcomeStep(
                        icon: "doc.text",
                        title: "建立事务并按需设提醒",
                        detail: "对单份凭证按需本机 OCR 识别，校对事实并确认日期后再安排系统通知。"
                    )
                }
                Divider()
                HStack(spacing: 12) {
                    Button("收纳文件…") { model.chooseImportFiles() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.storageUnavailable || model.isImporting)
                    Button("添加文件夹…") { model.addFolders() }
                        .disabled(model.storageUnavailable)
                    Spacer()
                    Button("查看使用指南", systemImage: "book") { openWindow(id: "guide") }
                        .buttonStyle(.link)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeStep(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
