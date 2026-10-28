import SwiftUI

private enum OrderFields {
    static let keys = ["product", "merchant", "order_number", "purchase_date", "received_date", "amount"]

    static func title(_ key: String) -> String {
        switch key {
        case "product": "商品"
        case "merchant": "商家"
        case "order_number": "订单号"
        case "purchase_date": "购买日期"
        case "received_date": "签收日期"
        case "amount": "金额"
        default: key
        }
    }

    static func valueType(_ key: String) -> String {
        if key.hasSuffix("_date") { return "date" }
        return key == "amount" ? "amount" : "text"
    }

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

    private var filtered: [MatterRecord] {
        model.matters.filter {
            model.search.isEmpty || $0.title.localizedStandardContains(model.search)
                || $0.notes.localizedStandardContains(model.search)
        }.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if model.matters.isEmpty {
                ContentUnavailableView {
                    Label("从一份订单开始跟进", systemImage: "doc.text")
                } description: {
                    Text("关联凭证、校对关键事实，再为需要处理的事确认提醒时间。")
                } actions: {
                    Button("创建订单事务") { model.createOrder() }.buttonStyle(.borderedProminent)
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else {
                Table(filtered, selection: $model.selectedMatterID, sortOrder: $sortOrder) {
                    TableColumn("订单", value: \.title) { matter in
                        Label(matter.title, systemImage: "doc.text").frame(height: 32)
                    }.width(min: 150, ideal: 230)
                    TableColumn("下一步") { matter in
                        let action = model.actions.first { $0.matterID == matter.id && ["active", "needs_date"].contains($0.state) }
                        Text(action?.title ?? "尚无待办").foregroundStyle(.secondary).lineLimit(1)
                    }.width(min: 100, ideal: 160)
                    TableColumn("凭证", value: \.itemCount) { Text($0.itemCount, format: .number) }
                        .width(min: 45, ideal: 55)
                    TableColumn("更新日期", value: \.updatedAt) {
                        Text($0.updatedAt.formatted(date: .numeric, time: .omitted)).foregroundStyle(.secondary)
                    }.width(min: 80, ideal: 100)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let matter = model.matters.first(where: { $0.id == id }) {
                        Button("查看事务") { Task { await model.showMatter(id) } }
                        Button("编辑订单") { Task { await model.editMatter(matter) } }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.selectedMatterID) { await model.loadMatterDetails() }
    }
}

struct MatterDetailView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var busyActionID: String?

    private var relatedActions: [ActionRecord] {
        model.actions.filter { $0.matterID == model.selectedMatterID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        if let matter = model.selectedMatter {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(matter.title, systemImage: "doc.text").font(.title2.bold()).textSelection(.enabled)
                        Text(matter.status == "completed" ? "订单 · 已完成" : "订单 · 跟进中")
                            .foregroundStyle(.secondary)
                        if let object = model.objects.first(where: { $0.id == matter.objectID }) {
                            Label(object.name, systemImage: "desktopcomputer").font(.callout).foregroundStyle(.secondary)
                        }
                        Button("编辑订单与行动", systemImage: "pencil") {
                            Task { await model.editMatter(matter) }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("相关凭证").font(.headline)
                        if model.matterFiles.isEmpty {
                            Text("尚未关联凭证。编辑订单可添加已有资料。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.matterFiles) { file in
                            VStack(alignment: .leading, spacing: 5) {
                                Button {
                                    Task { await model.showInLibrary(file) }
                                } label: {
                                    Label(file.name, systemImage: "doc").lineLimit(2)
                                }.buttonStyle(.link).help("在资料库中预览或打开此凭证")
                                Text(file.sourceName + " · " + (file.isAvailable ? "原件可用" : file.managedCopyPath != nil ? "原件不可用，可查看托管副本" : "原件不可用"))
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
                                    Text(OrderFields.title(fact.key)).font(.caption).foregroundStyle(.secondary)
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
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("行动与提醒").font(.headline)
                        if relatedActions.isEmpty {
                            Text("尚未设置行动").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(relatedActions) { action in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(action.title).font(.subheadline.bold()).textSelection(.enabled)
                                Text(OrderFields.stateTitle(action.state)).font(.caption).foregroundStyle(.secondary)
                                if let date = action.remindAt, action.dateConfirmed {
                                    Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                                        .font(.callout)
                                } else {
                                    Text("尚未确认具体提醒时间").font(.callout).foregroundStyle(.secondary)
                                }
                                if action.state == "active" {
                                    let pending = model.pendingActionIDs.contains(action.id)
                                    let delivered = model.deliveredActionIDs.contains(action.id)
                                    Label(pending ? "已安排系统提醒" : delivered ? "已送达通知中心" : "当前没有待发送通知",
                                          systemImage: pending ? "bell.badge" : delivered ? "bell" : "bell.slash")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if action.state == "active" || action.state == "needs_date" {
                                    HStack {
                                        Button("标记完成", systemImage: "checkmark") { update(action, state: "done") }
                                        Button("取消行动") { update(action, state: "cancelled") }
                                    }.controlSize(.small).disabled(busyActionID != nil)
                                } else {
                                    Button("编辑并重新启用") { Task { await model.editMatter(matter) } }
                                        .controlSize(.small)
                                }
                            }.padding(.vertical, 4)
                        }
                        if let message = model.reminderMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
                    Text("创建订单事务后，可以保存待补日期的行动，或确认具体时间并安排系统提醒。")
                } actions: {
                    Button("创建订单事务") { model.createOrder() }.buttonStyle(.borderedProminent)
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else {
                List(selection: $model.selectedActionID) {
                    actionSection("即将处理", state: "active")
                    actionSection("需要确认日期", state: "needs_date")
                    actionSection("已完成", state: "done")
                    actionSection("已取消", state: "cancelled")
                }.listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        if let date = action.remindAt, action.dateConfirmed {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("等待确认具体日期").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5).tag(action.id)
                        .contextMenu {
                            if let matterID = action.matterID {
                                Button("查看事务") { Task { await model.showMatter(matterID) } }
                            }
                            if state == "active" || state == "needs_date" {
                                Button("标记完成") { Task { await model.setActionState(action, state: "done") } }
                                Button("取消行动") { Task { await model.setActionState(action, state: "cancelled") } }
                            }
                        }
                        .onTapGesture(count: 2) {
                            if let matterID = action.matterID { Task { await model.showMatter(matterID) } }
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
    @State private var action: ActionDraft
    @State private var hasAction: Bool
    @State private var reminderDate: Date
    @State private var knownFiles: [String: LibraryFile] = [:]
    @State private var showFilePicker = false
    @State private var recognitionFileID: String?
    @State private var recognition: DocumentTextResult?
    @State private var recognitionError: String?
    @State private var importMessage: String?
    @State private var recognitionTask: Task<Void, Never>?
    @State private var showRecognizedText = true
    @State private var saving = false

    init(draft: MatterDraft) {
        var editable = draft
        for key in OrderFields.keys where !editable.facts.contains(where: { $0.key == key }) {
            editable.facts.append(FactDraft(key: key, valueType: OrderFields.valueType(key)))
        }
        var editableAction = draft.action ?? ActionDraft(title: "检查订单与售后")
        // A completed/cancelled action may retain its due date after its system reminder was removed.
        // Re-enabling it must not silently confirm a newly generated default reminder time.
        if editableAction.remindAt == nil { editableAction.dateConfirmed = false }
        _draft = State(initialValue: editable)
        _action = State(initialValue: editableAction)
        _hasAction = State(initialValue: draft.action != nil)
        _reminderDate = State(initialValue: draft.action?.remindAt ?? draft.action?.dueDate ?? Date().addingTimeInterval(3_600))
        _recognitionFileID = State(initialValue: draft.itemIDs.first)
    }

    private var attachedFiles: [LibraryFile] { draft.itemIDs.compactMap { knownFiles[$0] } }
    private var finishedAction: Bool { action.state == "done" || action.state == "cancelled" }
    private var invalidReminder: Bool {
        hasAction && !finishedAction && action.dateConfirmed && reminderDate <= Date()
    }
    private var canSave: Bool {
        !saving && recognitionTask == nil && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!hasAction || !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !invalidReminder
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.matters.contains(where: { $0.id == draft.id }) ? "编辑订单事务" : "创建订单事务")
                    .font(.title2.bold())
                Spacer()
            }.padding(24)
            Divider()
            Form {
                Section("订单") {
                    TextField("标题", text: $draft.title, prompt: Text("例如：我的电脑订单"))
                        .accessibilityIdentifier("matter-title")
                    Picker("关联对象", selection: $draft.objectID) {
                        Text("不关联对象").tag(String?.none)
                        ForEach(model.objects) { object in Text(object.name).tag(Optional(object.id)) }
                    }
                    Picker("事务状态", selection: $draft.status) {
                        Text("跟进中").tag("active")
                        Text("已完成").tag("completed")
                    }
                    LabeledContent("备注") {
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
                                .disabled(recognitionTask != nil)
                        }
                    }
                    Button("添加已有凭证", systemImage: "link.badge.plus") { showFilePicker = true }
                        .disabled(recognitionTask != nil)
                    if !attachedFiles.isEmpty {
                        Picker("识别凭证", selection: $recognitionFileID) {
                            Text("选择一份凭证").tag(String?.none)
                            ForEach(attachedFiles) { Text($0.name).tag(Optional($0.id)) }
                        }
                        HStack {
                            Button("识别并导入候选", systemImage: "text.viewfinder") { identify() }
                                .disabled(recognitionFileID.flatMap { knownFiles[$0] } == nil || recognitionTask != nil)
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
                    }
                } header: {
                    Text("凭证与文字识别")
                } footer: {
                    Text("识别只在点击后进行。候选不会覆盖已确认字段，也不会自动变成提醒日期。")
                }
                Section {
                    ForEach(OrderFields.keys, id: \.self) { key in
                        FactEditorRow(fact: factBinding(key), sourceName: sourceName(for: key))
                    }
                } header: {
                    Text("关键事实")
                } footer: {
                    Text("日期请填写 YYYY-MM-DD。未知可留空；购买日期不能代替签收日期，也不会推断退货截止日。")
                }
                Section {
                    Toggle("为订单保存一个行动", isOn: $hasAction)
                    if hasAction {
                        TextField("行动", text: $action.title, prompt: Text("例如：核对退货条件"))
                            .accessibilityIdentifier("action-title")
                        if finishedAction {
                            HStack {
                                Text("当前状态：" + OrderFields.stateTitle(action.state)).foregroundStyle(.secondary)
                                Spacer()
                                Button("重新启用行动") { action.state = action.dateConfirmed ? "active" : "needs_date" }
                            }
                        }
                        Toggle("我已确认具体提醒日期和时间", isOn: $action.dateConfirmed)
                            .accessibilityIdentifier("action-date-confirmed")
                        if action.dateConfirmed {
                            DatePicker("提醒时间", selection: $reminderDate, displayedComponents: [.date, .hourAndMinute])
                                .accessibilityIdentifier("action-reminder-date")
                            if invalidReminder {
                                Text("请选择未来的具体时间。仅修改事实日期不会建立提醒。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        } else {
                            Text("保存为「待补日期」，不会安排系统通知。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                    Button(saving ? "正在保存…" : "保存订单") { save() }
                        .keyboardShortcut(.defaultAction).disabled(!canSave)
                        .accessibilityIdentifier("matter-save")
                }
            }.padding(20)
        }
        .frame(minWidth: 600, idealWidth: 680, maxWidth: 900, minHeight: 540, idealHeight: 740, maxHeight: 1_000)
        .interactiveDismissDisabled(saving)
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
        .onDisappear { recognitionTask?.cancel(); recognitionTask = nil }
    }

    private func factBinding(_ key: String) -> Binding<FactDraft> {
        Binding(get: {
            draft.facts.first(where: { $0.key == key }) ?? FactDraft(key: key, valueType: OrderFields.valueType(key))
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
        // Facts retain their provenance; removing the visible link must not fabricate a new source.
    }

    private func identify() {
        guard let id = recognitionFileID, let file = knownFiles[id], recognitionTask == nil else { return }
        recognitionError = nil
        importMessage = nil
        recognition = nil
        recognitionTask = Task {
            defer { recognitionTask = nil }
            do {
                let result = try await model.extractText(from: file)
                try Task.checkCancellation()
                recognition = result
                var imported = 0
                var preserved = 0
                for suggestion in result.suggestions where OrderFields.keys.contains(suggestion.key) {
                    guard let index = draft.facts.firstIndex(where: { $0.key == suggestion.key }) else { continue }
                    if draft.facts[index].state == "confirmed" { preserved += 1; continue }
                    draft.facts[index].valueText = suggestion.valueText
                    draft.facts[index].valueType = suggestion.valueType
                    draft.facts[index].state = "candidate"
                    draft.facts[index].sourceItemID = file.id
                    draft.facts[index].sourceExcerpt = suggestion.sourceExcerpt
                    draft.facts[index].origin = "ocr"
                    imported += 1
                }
                if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let product = result.suggestions.first(where: { $0.key == "product" })?.valueText {
                    draft.title = product + "订单"
                }
                importMessage = imported == 0
                    ? "已显示识别原文，未导入新候选。请手动填写或校对已有字段。"
                    : "已导入 \(imported) 个候选，请逐项校对。" + (preserved > 0 ? "\(preserved) 个已确认字段保持不变。" : "")
            } catch is CancellationError { }
            catch { recognitionError = error.localizedDescription }
        }
    }

    private func save() {
        guard canSave else { return }
        var savedDraft = draft
        if hasAction {
            var savedAction = action
            savedAction.remindAt = action.dateConfirmed ? reminderDate : nil
            savedAction.dueDate = action.dateConfirmed ? reminderDate : nil
            if !finishedAction { savedAction.state = action.dateConfirmed ? "active" : "needs_date" }
            savedDraft.action = savedAction
        } else {
            savedDraft.action = nil
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
                TextField(OrderFields.title(fact.key), text: Binding(get: { fact.valueText }, set: {
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
            Text("添加订单凭证").font(.title2.bold())
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
