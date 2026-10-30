import SwiftUI

private enum ActionLabels {
    static func stateTitle(_ state: String) -> String {
        switch state {
        case "active": "待处理"
        case "needs_date": "待补日期"
        case "done": "已完成"
        case "cancelled": "已取消"
        default: state
        }
    }
}

struct MattersView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var sortOrder = [KeyPathComparator(\MatterRecord.updatedAt, order: .reverse)]
    @State private var kindFilter = "all"
    @State private var statusFilter = "all"

    private var filtered: [MatterRecord] {
        model.matters.filter {
            (kindFilter == "all" || $0.kind == kindFilter)
                && (statusFilter == "all" || $0.status == statusFilter)
                && (model.search.isEmpty || $0.title.localizedStandardContains(model.search)
                    || $0.notes.localizedStandardContains(model.search))
        }.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if model.matters.isEmpty {
                ContentUnavailableView {
                    Label("从一份凭证开始跟进", systemImage: "doc.text")
                } description: {
                    Text("创建订单、合同、保修或订阅，关联凭证、校对事实，再确认行动的提醒时间。")
                } actions: {
                    Button("创建事务") { model.createMatter(kind: .order) }.buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        Picker("类型", selection: $kindFilter) {
                            Text("全部类型").tag("all")
                            ForEach(MatterKind.allCases) { Text($0.title).tag($0.rawValue) }
                        }.frame(maxWidth: 190)
                        Picker("状态", selection: $statusFilter) {
                            Text("全部状态").tag("all")
                            Text("跟进中").tag("active")
                            Text("已完成").tag("completed")
                        }.frame(maxWidth: 170)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                    Divider()
                    if filtered.isEmpty {
                        ContentUnavailableView {
                            Label("没有匹配的事务", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("调整类型、状态或搜索关键词。")
                        } actions: {
                            Button("清除筛选") { kindFilter = "all"; statusFilter = "all"; model.search = "" }
                        }
                    } else {
                        matterTable
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.selectedMatterID) { await model.loadMatterDetails() }
        .onChange(of: filtered.map(\.id)) { _, visibleIDs in
            if let id = model.selectedMatterID, !visibleIDs.contains(id) { model.selectedMatterID = nil }
        }
        .onChange(of: model.selectedMatterID) { _, id in
            // Explicit navigation (new matter or notification) must reveal its row.
            if let id, model.matters.contains(where: { $0.id == id }),
               !filtered.contains(where: { $0.id == id }) {
                kindFilter = "all"
                statusFilter = "all"
                model.search = ""
            }
        }
    }

    private var matterTable: some View {
        Table(filtered, selection: $model.selectedMatterID, sortOrder: $sortOrder) {
            TableColumn("事务", value: \.title) { matter in
                Label(matter.title, systemImage: (MatterKind(rawValue: matter.kind) ?? .order).image).frame(height: 28)
            }.width(min: 150, ideal: 210)
            TableColumn("类型", value: \.kind) { matter in
                Text((MatterKind(rawValue: matter.kind) ?? .order).title).foregroundStyle(.secondary)
            }.width(min: 50, ideal: 65)
            TableColumn("下一步") { matter in
                let action = model.actions.first { $0.matterID == matter.id && ["active", "needs_date"].contains($0.state) }
                Text(action?.title ?? "尚无待办").foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 100, ideal: 150)
            TableColumn("凭证", value: \.itemCount) { Text($0.itemCount, format: .number) }
                .width(min: 45, ideal: 55)
            TableColumn("更新日期", value: \.updatedAt) {
                Text($0.updatedAt.formatted(date: .numeric, time: .omitted)).foregroundStyle(.secondary)
            }.width(min: 80, ideal: 100)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let matter = model.matters.first(where: { $0.id == id }) {
                Button("查看事务") { Task { await model.showMatter(id) } }
                Button("编辑事务") { Task { await model.editMatter(matter) } }
            }
        } primaryAction: { ids in
            if let id = ids.first { Task { await model.showMatter(id) } }
        }
        .onKeyPress(.return) {
            guard let id = model.selectedMatterID else { return .ignored }
            Task { await model.showMatter(id) }
            return .handled
        }
    }
}

struct MatterDetailView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var busyActionID: String?
    @State private var editingAction: ActionDraft?
    @State private var showFinishedActions = false

    private var relatedActions: [ActionRecord] {
        model.actions.filter { $0.matterID == model.selectedMatterID }

    }

    var body: some View {
        if let matter = model.selectedMatter {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(matter.title, systemImage: (MatterKind(rawValue: matter.kind) ?? .order).image).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text((MatterKind(rawValue: matter.kind) ?? .order).title + (matter.status == "completed" ? " · 已完成" : " · 跟进中"))
                            .foregroundStyle(.secondary)
                        ForEach(Array(model.matterFacts.filter { $0.state == "confirmed" && $0.valueType == "date" }.prefix(2))) { fact in
                            LabeledContent(MatterKind.title(for: fact.key), value: fact.valueText)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let object = model.objects.first(where: { $0.id == matter.objectID }) {
                            Label(object.name, systemImage: "desktopcomputer").font(.callout).foregroundStyle(.secondary)
                        }
                        Button("编辑事务与行动", systemImage: "pencil") {
                            Task { await model.editMatter(matter) }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("行动与提醒").font(.headline)
                        if relatedActions.isEmpty {
                            Text("尚未设置行动").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(relatedActions.filter { showFinishedActions || ["active", "needs_date"].contains($0.state) || model.selectedActionID == $0.id }) { action in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(action.title).font(.callout.weight(.medium)).textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Menu {
                                        Button("编辑行动…") { editingAction = ActionDraft(action) }
                                        if ["active", "needs_date"].contains(action.state) {
                                            Button("取消行动") { update(action, state: "cancelled") }
                                        }
                                    } label: { Image(systemName: "ellipsis") }
                                        .menuStyle(.borderlessButton).fixedSize().disabled(busyActionID != nil)
                                        .accessibilityLabel(action.title + "的操作")
                                }
                                HStack {
                                    Text(ActionLabels.stateTitle(action.state)).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if ["active", "needs_date"].contains(action.state) {
                                        Button("标记完成", systemImage: "checkmark") { update(action, state: "done") }
                                            .controlSize(.small).disabled(busyActionID != nil)
                                    }
                                }
                                ActionTimingView(action: action)
                            }.padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedActionID == action.id ? Color.accentColor.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .id(action.id)
                        }
                        let finishedCount = relatedActions.filter { ["done", "cancelled"].contains($0.state) }.count
                        if finishedCount > 0 {
                            Toggle("显示已完成和已取消（\(finishedCount)）", isOn: $showFinishedActions)
                                .toggleStyle(.checkbox).font(.caption)
                        }
                        Button("添加行动", systemImage: "plus") { editingAction = ActionDraft() }
                        if let message = model.reminderMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("相关凭证").font(.headline)
                        if model.matterFiles.isEmpty {
                            Text("尚未关联凭证。编辑事务可添加已有资料。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.matterFiles) { file in
                            VStack(alignment: .leading, spacing: 5) {
                                Button {
                                    Task { await model.showInLibrary(file) }
                                } label: {
                                    Label(file.name, systemImage: "doc").lineLimit(2)
                                }.buttonStyle(.link).help("在资料库中预览或打开此凭证")
                                Text(file.sourceName + " · " + (file.isImported ? "托管副本" : file.isAvailable ? "原件可用" : file.managedCopyPath != nil ? "原件不可用，可查看托管副本" : "原件不可用"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("关键事实").font(.headline)
                        if model.matterFacts.isEmpty {
                            Text("尚未填写事实。可识别凭证后校对，也可直接手动填写。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.matterFacts) { fact in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(MatterKind.title(for: fact.key)).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Label(fact.state == "confirmed" ? "已确认" : "候选",
                                          systemImage: fact.state == "confirmed" ? "checkmark.circle" : "questionmark.circle")
                                        .font(.caption).foregroundStyle(fact.state == "confirmed" ? Color.secondary : Color.orange)
                                }
                                Text(fact.valueText).textSelection(.enabled)
                                if let sourceID = fact.sourceItemID,
                                   let file = model.matterFiles.first(where: { $0.id == sourceID }) {
                                    Text("出处：" + file.name).font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(fact.origin == "user" ? "手动填写" : "来源资料暂不可用")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let excerpt = fact.sourceExcerpt, !excerpt.isEmpty {
                                    Text("“\(excerpt)”").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !matter.notes.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("备注").font(.headline)
                            Text(matter.notes).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .task(id: "\(matter.id)|\(model.selectedActionID ?? "")|\(relatedActions.map(\.id))") {
                if let id = model.selectedActionID, relatedActions.contains(where: { $0.id == id }) {
                    await Task.yield()
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            }
            .sheet(item: $editingAction) { action in
                ActionEditorView(draft: action) { await model.saveAction($0, matterID: matter.id) }
            }
        } else {
            ContentUnavailableView("选择一条事务", systemImage: "doc.text",
                                   description: Text("查看事实、相关凭证和下一步行动。"))
        }
    }

    private func update(_ action: ActionRecord, state: String) {
        busyActionID = action.id
        Task {
            await model.setActionState(action, state: state)
            busyActionID = nil
        }
    }
}

struct ActionsView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var editingAction: ActionDraft?
    @State private var editingMatterID: String?
    @State private var showFinished = false

    private var filtered: [ActionRecord] {
        model.actions.filter {
            model.search.isEmpty || $0.title.localizedStandardContains(model.search)
                || ($0.matterTitle?.localizedStandardContains(model.search) ?? false)
        }.sorted { ($0.remindAt ?? .distantFuture) < ($1.remindAt ?? .distantFuture) }
    }

    var body: some View {
        Group {
            if model.actions.isEmpty {
                ContentUnavailableView {
                    Label("把下一步留在这里", systemImage: "checklist")
                } description: {
                    Text("创建事务后，可以保存待补日期的行动，或确认具体时间并安排系统提醒。")
                } actions: {
                    Button("创建事务") { model.createMatter(kind: .order) }.buttonStyle(.borderedProminent)
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else {
                VStack(spacing: 0) {
                Toggle("显示已完成和已取消", isOn: $showFinished).toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                List(selection: $model.selectedActionID) {
                    actionSection("待处理", state: "active")
                    actionSection("需要确认日期", state: "needs_date")
                    if showFinished {
                        actionSection("已完成", state: "done")
                        actionSection("已取消", state: "cancelled")
                    }
                    if !showFinished && filtered.allSatisfy({ ["done", "cancelled"].contains($0.state) }) {
                        Text("暂无待处理行动").foregroundStyle(.secondary)
                    }
                }.listStyle(.inset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editingAction) { action in
            if let matterID = editingMatterID {
                ActionEditorView(draft: action) { await model.saveAction($0, matterID: matterID) }
            }
        }
        .onChange(of: model.selectedActionID) { _, id in
            model.selectedMatterID = model.actions.first(where: { $0.id == id })?.matterID
            Task { await model.loadMatterDetails() }
        }
    }

    @ViewBuilder private func actionSection(_ title: String, state: String) -> some View {
        let actions = filtered.filter { $0.state == state }
        if !actions.isEmpty {
            Section(title) {
                ForEach(actions) { action in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(action.title, systemImage: state == "done" ? "checkmark.circle" : state == "cancelled" ? "minus.circle" : "circle")
                                .lineLimit(2)
                            Spacer()
                            if model.pendingActionIDs.contains(action.id) {
                                Image(systemName: "bell.badge").foregroundStyle(.secondary).help("已安排系统提醒")
                            }
                        }
                        if let matterTitle = action.matterTitle {
                            Text(matterTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        ActionTimingView(action: action)
                        HStack {
                            if ["active", "needs_date"].contains(action.state) {
                                Button("完成", systemImage: "checkmark") { Task { await model.setActionState(action, state: "done") } }
                            }
                            Menu("更多", systemImage: "ellipsis") {
                                Button("编辑行动…") {
                                    editingMatterID = action.matterID
                                    editingAction = ActionDraft(action)
                                }
                                if let matterID = action.matterID {
                                    Button("查看事务与凭证") { Task { await model.showMatter(matterID, actionID: action.id) } }
                                }
                                if ["active", "needs_date"].contains(action.state) {
                                    Button("取消行动") { Task { await model.setActionState(action, state: "cancelled") } }
                                }
                            }.menuStyle(.borderlessButton).fixedSize()
                        }.controlSize(.small)
                    }.padding(.vertical, 5).tag(action.id)
                        .contextMenu {
                            if let matterID = action.matterID {
                                Button("查看事务") { Task { await model.showMatter(matterID, actionID: action.id) } }
                            }
                            if state == "active" || state == "needs_date" {
                                Button("标记完成") { Task { await model.setActionState(action, state: "done") } }
                                Button("取消行动") { Task { await model.setActionState(action, state: "cancelled") } }
                            }
                        }
                        .onTapGesture(count: 2) {
                            if let matterID = action.matterID { Task { await model.showMatter(matterID, actionID: action.id) } }
                        }
                }
            }
        }
    }
}

struct MatterEditorView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MatterDraft
    private let originalActions: [ActionDraft]
    @State private var editingAction: ActionDraft?
    @State private var knownFiles: [String: LibraryFile] = [:]
    @State private var showFilePicker = false
    @State private var recognitionFileID: String?
    @State private var recognizedFileID: String?
    @State private var recognition: DocumentTextResult?
    @State private var recognitionError: String?
    @State private var importMessage: String?
    @State private var recognitionTask: Task<Void, Never>?
    @State private var assistantTask: Task<Void, Never>?
    @State private var assistantError: String?
    @State private var savingText = false
    @State private var textSaved = false
    @State private var textSaveMessage: String?
    @State private var showRecognizedText = true
    @State private var saving = false
    @State private var showNotes: Bool

    init(draft: MatterDraft) {
        var editable = draft
        let kind = MatterKind(rawValue: draft.kind) ?? .order
        for key in kind.fieldKeys where !editable.facts.contains(where: { $0.key == key }) {
            editable.facts.append(FactDraft(key: key, valueType: MatterKind.valueType(for: key)))
        }
        originalActions = draft.actions
        _draft = State(initialValue: editable)
        _showNotes = State(initialValue: !draft.notes.isEmpty)
        _recognitionFileID = State(initialValue: draft.itemIDs.first)
    }

    private var attachedFiles: [LibraryFile] { draft.itemIDs.compactMap { knownFiles[$0] } }
    private var kind: MatterKind { MatterKind(rawValue: draft.kind) ?? .order }
    private var editing: Bool { model.matters.contains(where: { $0.id == draft.id }) }
    private var processingText: Bool { recognitionTask != nil || assistantTask != nil || savingText }
    private var extraFieldKeys: [String] {
        draft.facts.filter { !kind.fieldKeys.contains($0.key) && !$0.valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.key)
    }
    private var canSave: Bool {
        !saving && !processingText && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((editing ? "编辑" : "创建") + kind.title + "事务")
                    .font(.title2.bold())
                Spacer()
            }.padding(24)
            Divider()
            Form {
                Section("事务") {
                    Picker("类型", selection: $draft.kind) {
                        ForEach(MatterKind.allCases) { Label($0.title, systemImage: $0.image).tag($0.rawValue) }
                    }.disabled(editing || processingText)
                        .help(editing ? "已有事务的类型保留不变；不同类型可新建事务。" : "选择要跟进的事务类型")
                        .accessibilityIdentifier("matter-kind")
                    TextField("标题", text: $draft.title, prompt: Text("为这份" + kind.title + "填写便于查找的标题"))
                        .accessibilityIdentifier("matter-title")
                    Picker("关联对象", selection: $draft.objectID) {
                        Text("不关联对象").tag(String?.none)
                        ForEach(model.objects) { object in Text(object.name).tag(Optional(object.id)) }
                    }
                    if let message = model.matterObjectSelectionMessage, !editing {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("事务状态", selection: $draft.status) {
                        Text("跟进中").tag("active")
                        Text("已完成").tag("completed")
                    }
                    DisclosureGroup("备注（可选）", isExpanded: $showNotes) {
                        TextEditor(text: $draft.notes).frame(minHeight: 50, idealHeight: 65).border(.separator)
                            .accessibilityIdentifier("matter-notes")
                    }
                }
                Section {
                    if draft.itemIDs.isEmpty {
                        Text("可以关联已有的 PDF 或图片凭证，也可以直接手动填写。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(draft.itemIDs, id: \.self) { id in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(knownFiles[id]?.name ?? "资料暂不可用", systemImage: "doc").lineLimit(2)
                                if let file = knownFiles[id] {
                                    Text(file.sourceName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("解除关联", systemImage: "xmark") { removeFile(id) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .help("仅解除凭证关联，保留原文件")
                                .disabled(processingText)
                        }
                    }
                    Button("添加已有凭证", systemImage: "link.badge.plus") { showFilePicker = true }
                        .disabled(processingText)
                    if !attachedFiles.isEmpty {
                        Picker("识别凭证", selection: $recognitionFileID) {
                            Text("选择一份凭证").tag(String?.none)
                            ForEach(attachedFiles) { Text($0.name).tag(Optional($0.id)) }
                        }.disabled(processingText)
                        HStack {
                            Button("识别并导入候选", systemImage: "text.viewfinder") { identify() }
                                .disabled(recognitionFileID.flatMap { knownFiles[$0] } == nil || processingText)
                                .accessibilityIdentifier("matter-recognize")
                            if recognitionTask != nil {
                                ProgressView().controlSize(.small)
                                Text("正在本机识别…").foregroundStyle(.secondary)
                                Button("停止") { recognitionTask?.cancel() }.buttonStyle(.link)
                            }
                        }
                    }
                    if let recognitionError { Text(recognitionError).font(.callout).foregroundStyle(.orange) }
                    if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
                    if let recognition {
                        if let note = recognition.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        DisclosureGroup("识别原文", isExpanded: $showRecognizedText) {
                            ScrollView {
                                Text(recognition.text).frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled).font(.callout).padding(8)
                            }.frame(minHeight: 100, idealHeight: 150, maxHeight: 240).background(.background)
                        }
                        recognizedTextActions
                    }
                } header: {
                    Text("凭证与文字识别")
                } footer: {
                    Text("识别只在点击后进行。候选不会覆盖已确认字段，也不会自动变成提醒日期。")
                }
                Section {
                    ForEach(kind.fieldKeys, id: \.self) { key in
                        FactEditorRow(fact: factBinding(key), sourceName: sourceName(for: key))
                    }
                } header: {
                    Text("关键事实")
                } footer: {
                    Text("日期请填写 YYYY-MM-DD，未知可留空。这里只记录原文或手动确认的事实，不会推断退货、续约或取消截止日。")
                }
                if !extraFieldKeys.isEmpty {
                    Section("其它已填字段") {
                        ForEach(extraFieldKeys, id: \.self) { key in
                            FactEditorRow(fact: factBinding(key), sourceName: sourceName(for: key))
                        }
                        Text("这些字段来自之前选择的类型，保留其内容供你核对；清空后不会保存。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if draft.actions.isEmpty {
                        Text("尚无行动。可添加多条独立行动，日期未知时先保存为待补日期。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(draft.actions) { action in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(action.title).font(.headline)
                                Text(ActionLabels.stateTitle(action.state)).font(.caption).foregroundStyle(.secondary)
                                if let date = action.remindAt, action.dateConfirmed {
                                    Text("提醒：" + date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("编辑") { editingAction = action }
                            if ["active", "needs_date"].contains(action.state) {
                                Button("完成") { changeAction(action, state: "done") }
                                Button("取消行动") { changeAction(action, state: "cancelled") }
                            }
                        }
                    }
                    Button("添加行动", systemImage: "plus") { editingAction = ActionDraft(title: kind.defaultActionTitle) }
                } header: {
                    Text("行动与系统提醒")
                } footer: {
                    Text("系统通知使用通用文案。只有用户确认的未来时间才会安排；通知被拒绝时，行动仍会保存并显示真实状态。")
                }
            }.formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let message = model.errorMessage { Text(message).font(.callout).foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving || savingText)
                    Button(saving ? "正在保存…" : "保存" + kind.title) { save() }
                        .keyboardShortcut(.defaultAction).disabled(!canSave)
                        .accessibilityIdentifier("matter-save")
                }
            }.padding(20)
        }
        .frame(minWidth: 600, idealWidth: 680, maxWidth: 900, minHeight: 540, idealHeight: 740, maxHeight: 1_000)
        .interactiveDismissDisabled(saving || savingText)
        .sheet(isPresented: $showFilePicker) {
            MatterFilePickerSheet { files in
                for file in files {
                    knownFiles[file.id] = file
                    if !draft.itemIDs.contains(file.id) { draft.itemIDs.append(file.id) }
                }
                if recognitionFileID == nil { recognitionFileID = files.first?.id }
            }.environmentObject(model)
        }
        .task {
            if let file = model.selectedFile, draft.itemIDs.contains(file.id) { knownFiles[file.id] = file }
            for file in model.matterFiles where draft.itemIDs.contains(file.id) { knownFiles[file.id] = file }
            do {
                for file in try await model.availableFiles(search: "", managedOnly: false) where draft.itemIDs.contains(file.id) {
                    knownFiles[file.id] = file
                }
            } catch is CancellationError { }
            catch { recognitionError = "无法读取已有凭证。仍可手动填写，或重新添加凭证。" }
        }
        .onChange(of: draft.kind) { previous, current in
            let newKind = MatterKind(rawValue: current) ?? .order
            for key in newKind.fieldKeys where !draft.facts.contains(where: { $0.key == key }) {
                draft.facts.append(FactDraft(key: key, valueType: MatterKind.valueType(for: key)))
            }
        }
        .sheet(item: $editingAction) { action in
            ActionEditorView(draft: action, savesToMatterDraft: true) { edited in
                if let index = draft.actions.firstIndex(where: { $0.id == edited.id }) {
                    draft.actions[index] = edited
                } else { draft.actions.append(edited) }
                return true
            }
        }

        .onDisappear {
            recognitionTask?.cancel(); recognitionTask = nil
            assistantTask?.cancel(); assistantTask = nil
        }
    }

    @ViewBuilder private var recognizedTextActions: some View {
        if let result = recognition, let id = recognizedFileID, let file = knownFiles[id] {
            VStack(alignment: .leading, spacing: 10) {
                Text("以下操作针对：" + file.name).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("用本机模型建议字段", systemImage: "text.badge.plus") { suggestWithLocalModel() }
                        .disabled(!LocalFactAssistant.isAvailable || processingText)
                        .accessibilityIdentifier("matter-local-model")
                    if assistantTask != nil {
                        ProgressView().controlSize(.small)
                        Button("停止") { assistantTask?.cancel() }.buttonStyle(.link)
                    }
                }
                Text(LocalFactAssistant.availabilityMessage()).font(.caption).foregroundStyle(.secondary)
                Text("本机模型只查看识别原文的前 3500 个字符。结果均为候选，需逐项校对；已确认字段不会被覆盖。")
                    .font(.caption).foregroundStyle(.secondary)
                if let assistantError { Text(assistantError).font(.callout).foregroundStyle(.orange) }
                Divider()
                HStack {
                    Button(savingText ? "正在保存正文…" : "保存此正文供全文搜索", systemImage: "doc.text.magnifyingglass") {
                        saveText(file: file, text: result.text)
                    }.disabled(processingText || textSaved)
                        .accessibilityIdentifier("matter-save-document-text")
                    if savingText { ProgressView().controlSize(.small) }
                }
                Text("默认不保存正文。此操作会把识别正文以明文保存在本机数据库，用于全文搜索；仅适合普通凭证，请勿用于密码、恢复码或其它秘密。")
                    .font(.caption).foregroundStyle(.secondary)
                if let textSaveMessage {
                    Text(textSaveMessage).font(.caption).foregroundStyle(textSaved ? Color.secondary : Color.orange)
                }
            }.padding(.vertical, 6)
        }
    }

    private func factBinding(_ key: String) -> Binding<FactDraft> {
        Binding(get: {
            draft.facts.first(where: { $0.key == key }) ?? FactDraft(key: key, valueType: MatterKind.valueType(for: key))
        }, set: { value in
            if let index = draft.facts.firstIndex(where: { $0.key == key }) { draft.facts[index] = value }
        })
    }

    private func sourceName(for key: String) -> String? {
        guard let id = draft.facts.first(where: { $0.key == key })?.sourceItemID else { return nil }
        return knownFiles[id]?.name ?? "来源资料暂不可用"
    }

    private func removeFile(_ id: String) {
        draft.itemIDs.removeAll { $0 == id }
        if recognitionFileID == id { recognitionFileID = draft.itemIDs.first }
        if recognizedFileID == id {
            recognizedFileID = nil
            recognition = nil
            importMessage = nil
            assistantError = nil
            textSaved = false
            textSaveMessage = nil
        }
        // Facts retain their provenance; removing the visible link must not fabricate a new source.
    }

    private func identify() {
        guard let id = recognitionFileID, let file = knownFiles[id], !processingText else { return }
        recognitionError = nil
        importMessage = nil
        recognition = nil
        recognizedFileID = nil
        assistantError = nil
        textSaved = false
        textSaveMessage = nil
        recognitionTask = Task {
            defer { recognitionTask = nil }
            do {
                let result = try await model.extractText(from: file)
                try Task.checkCancellation()
                recognition = result
                recognizedFileID = file.id
                importCandidates(result.suggestions, from: file, origin: "ocr")
            } catch is CancellationError { }
            catch { recognitionError = error.localizedDescription }
        }
    }

    private func suggestWithLocalModel() {
        guard !processingText, LocalFactAssistant.isAvailable,
              let result = recognition, let id = recognizedFileID, let file = knownFiles[id] else { return }
        assistantError = nil
        assistantTask = Task {
            defer { assistantTask = nil }
            do {
                let suggestions = try await model.suggestFacts(file: file, text: String(result.text.prefix(3_500)),
                    allowedKeys: kind.fieldKeys)
                try Task.checkCancellation()
                importCandidates(suggestions, from: file, origin: "model")
            } catch is CancellationError { }
            catch { assistantError = error.localizedDescription }
        }
    }

    private func importCandidates(_ suggestions: [DocumentFactSuggestion], from file: LibraryFile, origin: String) {
        var imported = 0
        var preserved = 0
        for suggestion in suggestions where kind.fieldKeys.contains(suggestion.key) {
            guard let index = draft.facts.firstIndex(where: { $0.key == suggestion.key }) else { continue }
            if draft.facts[index].state == "confirmed" { preserved += 1; continue }
            draft.facts[index].valueText = suggestion.valueText
            draft.facts[index].valueType = MatterKind.valueType(for: suggestion.key)
            draft.facts[index].state = "candidate"
            draft.facts[index].sourceItemID = file.id
            draft.facts[index].sourceExcerpt = suggestion.sourceExcerpt
            draft.facts[index].origin = origin
            imported += 1
        }
        let titleKey: String
        switch kind {
        case .order, .warranty: titleKey = "product"
        case .contract: titleKey = "counterparty"
        case .subscription: titleKey = "service"
        }
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let title = suggestions.first(where: { $0.key == titleKey })?.valueText {
            draft.title = title + kind.title
        }
        importMessage = imported == 0
            ? "未导入新候选。请对照原文手动填写，或校对已有字段。"
            : "已导入 \(imported) 个候选，请逐项校对。" + (preserved > 0 ? "\(preserved) 个已确认字段保持不变。" : "")
    }

    private func saveText(file: LibraryFile, text: String) {
        guard !processingText, !textSaved else { return }
        savingText = true
        textSaveMessage = nil
        Task {
            textSaved = await model.saveDocumentText(file: file, text: text)
            textSaveMessage = textSaved ? "此凭证的识别正文已保存，可在资料库中启用全文搜索。" : "正文未保存，请检查提示后重试。"
            savingText = false
        }
    }

    private func changeAction(_ action: ActionDraft, state: String) {
        if let index = draft.actions.firstIndex(where: { $0.id == action.id }) { draft.actions[index].state = state }
    }

    private func save() {
        guard canSave else { return }
        var savedDraft = draft
        // Metadata edits submit only actions changed in this editor; other rows stay untouched.
        savedDraft.actions = draft.actions.filter { edited in
            originalActions.first(where: { $0.id == edited.id }) != edited
        }
        saving = true
        Task {
            if await model.saveMatter(savedDraft) { dismiss() }
            saving = false
        }
    }
}

private struct FactEditorRow: View {
    @Binding var fact: FactDraft
    let sourceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField(MatterKind.title(for: fact.key), text: Binding(get: { fact.valueText }, set: {
                    guard fact.valueText != $0 else { return }
                    fact.valueText = $0
                    fact.origin = "user"
                    fact.state = "candidate"
                }), prompt: Text(fact.valueType == "date" ? "YYYY-MM-DD；未知可留空" : "未知可留空"))
                    .accessibilityIdentifier("fact-\(fact.key)")
                Toggle("已确认", isOn: Binding(get: { fact.state == "confirmed" }, set: {
                    fact.state = $0 ? "confirmed" : "candidate"
                })).toggleStyle(.checkbox).fixedSize()
                    .disabled(fact.valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("fact-confirm-\(fact.key)")
            }
            HStack(alignment: .top, spacing: 6) {
                Text(fact.state == "confirmed" ? "已确认" : "候选").foregroundStyle(fact.state == "confirmed" ? Color.secondary : Color.orange)
                Text(sourceName.map { "出处：" + $0 } ?? "手动填写").foregroundStyle(.secondary)
            }.font(.caption)
            if let excerpt = fact.sourceExcerpt, !excerpt.isEmpty {
                Text("原文：\(excerpt)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(.vertical, 3)
    }
}

private struct MatterFilePickerSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let add: ([LibraryFile]) -> Void
    @State private var search = ""
    @State private var managedOnly = false
    @State private var candidates: [LibraryFile] = []
    @State private var selected: Set<String> = []
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加事务凭证").font(.title2.bold())
            HStack {
                TextField("搜索名称或路径", text: $search)
                Toggle("仅已托管", isOn: $managedOnly).toggleStyle(.checkbox)
            }
            Text("可按住 ⌘ 选择多份资料。这里只建立关联，原文件保留在原位置。")
                .font(.caption).foregroundStyle(.secondary)
            Table(candidates, selection: $selected) {
                TableColumn("名称", value: \.name)
                TableColumn("来源", value: \.sourceName).width(min: 80, ideal: 120)
            }
            if loading { ProgressView("正在读取资料…").controlSize(.small) }
            if let loadError { Text(loadError).foregroundStyle(.orange).font(.callout) }
            HStack {
                Text("已选择 \(selected.count) 份").foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加所选凭证") {
                    add(candidates.filter { selected.contains($0.id) })
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(selected.isEmpty || loading)
            }
        }.padding(24).frame(minWidth: 580, idealWidth: 640, minHeight: 400, idealHeight: 460)
            .task(id: "\(search)|\(managedOnly)") {
                loading = true
                defer { loading = false }
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    let files = try await model.availableFiles(search: search, managedOnly: managedOnly)
                    try Task.checkCancellation()
                    candidates = files
                    selected.formIntersection(Set(files.map(\.id)))
                    loadError = nil
                } catch is CancellationError { }
                catch { loadError = "无法读取资料，请重试。" }
            }
    }
}
