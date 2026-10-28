import SwiftUI

extension PersonalObject {
    var kindTitle: String { kind == "device" ? "设备" : "其它" }
}

struct ObjectsView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var sortOrder = [KeyPathComparator(\PersonalObject.name)]
    private var filtered: [PersonalObject] {
        model.objects.filter { model.search.isEmpty || $0.name.localizedStandardContains(model.search)
            || $0.notes.localizedStandardContains(model.search) }.sorted(using: sortOrder)
    }
    var body: some View {
        if model.objects.isEmpty {
            ContentUnavailableView {
                Label("把资料关联到你关心的事物", systemImage: "desktopcomputer")
            } description: {
                Text("创建设备或其它个人对象，再关联已有资料。文件保留在原位置。")
            } actions: {
                Button("创建个人对象") { model.createObject() }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: model.search)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(filtered, selection: $model.selectedObjectID, sortOrder: $sortOrder) {
                TableColumn("名称", value: \.name) { object in
                    Label(object.name, systemImage: object.kind == "device" ? "desktopcomputer" : "square.stack.3d.up")
                        .frame(height: 30)
                }.width(min: 150, ideal: 220)
                TableColumn("类别", value: \.kind) { Text($0.kindTitle).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 70)
                TableColumn("关联资料", value: \.itemCount) { Text($0.itemCount, format: .number) }
                    .width(min: 65, ideal: 80)
                TableColumn("更新日期", value: \.updatedAt) { object in
                    Text(object.updatedAt.formatted(date: .numeric, time: .omitted)).foregroundStyle(.secondary)
                }.width(min: 80, ideal: 100)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let object = model.objects.first(where: { $0.id == id }) {
                    Button("查看关联资料") { model.showObject(id) }
                    Button("编辑对象") { model.editObject(object) }
                }
            } primaryAction: { ids in
                if let id = ids.first { model.showObject(id) }
            }
            .onKeyPress(.return) {
                guard let id = model.selectedObjectID else { return .ignored }
                model.showObject(id)
                return .handled
            }
        }
    }
}

struct ObjectInfoView: View {
    @EnvironmentObject private var model: LibraryModel
    var body: some View {
        if let object = model.selectedObject {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(object.name, systemImage: object.kind == "device" ? "desktopcomputer" : "square.stack.3d.up")
                        .font(.title2.bold()).textSelection(.enabled)
                    Text("\(object.kindTitle) · \(object.itemCount) 份关联资料").foregroundStyle(.secondary)
                    Button("查看关联资料", systemImage: "doc.on.doc") { model.showObject(object.id) }
                        .buttonStyle(.borderedProminent)
                    Button("编辑名称和备注", systemImage: "pencil") { model.editObject(object) }
                    Divider()
                    Text("备注").font(.headline)
                    Text(object.notes.isEmpty ? "尚未填写备注" : object.notes)
                        .foregroundStyle(object.notes.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                    Text("创建于 " + object.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("关联仅保存关系，不会移动或修改原文件。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        } else {
            ContentUnavailableView("选择一个个人对象", systemImage: "desktopcomputer",
                description: Text("查看备注和关联资料，或创建一个新对象。"))
        }
    }
}

struct ObjectEditorView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    private let editing: Bool
    @State private var id: String
    @State private var name: String
    @State private var kind: String
    @State private var notes: String
    @State private var saving = false

    init(object: PersonalObject?) {
        editing = object != nil
        _id = State(initialValue: object?.id ?? UUID().uuidString)
        _name = State(initialValue: object?.name ?? "")
        _kind = State(initialValue: object?.kind ?? "device")
        _notes = State(initialValue: object?.notes ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(editing ? "编辑个人对象" : "创建个人对象").font(.title2.bold())
            Form {
                TextField("名称", text: $name, prompt: Text("例如：我的电脑"))
                    .accessibilityIdentifier("object-name")
                Picker("类别", selection: $kind) {
                    Text("设备").tag("device")
                    Text("其它").tag("other")
                }
                LabeledContent("备注") {
                    TextEditor(text: $notes).frame(height: 90).border(.separator)
                        .accessibilityIdentifier("object-notes")
                }
            }
            if let message = model.errorMessage {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "正在保存…" : "保存") {
                    saving = true
                    Task {
                        if await model.saveObject(id: id, name: name, kind: kind, notes: notes) { dismiss() }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 450)
    }
}

struct LinkToObjectSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("关联到个人对象").font(.title2.bold())
            Text(model.selectedFile?.name ?? "选择对象").foregroundStyle(.secondary)
            if model.objects.isEmpty {
                Text("先在「个人对象」中创建一个对象，再关联资料。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
            } else {
                List(model.objects) { object in
                    HStack {
                        Label(object.name, systemImage: object.kind == "device" ? "desktopcomputer" : "square.stack.3d.up")
                        Spacer()
                        if model.linkedObjects.contains(where: { $0.id == object.id }) {
                            Label("已关联", systemImage: "checkmark").foregroundStyle(.secondary)
                        } else {
                            Button("关联") {
                                guard let file = model.selectedFile else { return }
                                saving = true
                                Task {
                                    if await model.linkItems([file.id], to: object.id) { dismiss() }
                                    saving = false
                                }
                            }.disabled(saving).accessibilityLabel("关联到「\(object.name)」")
                        }
                    }.padding(.vertical, 5).accessibilityElement(children: .contain)
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 460, height: 330)
    }
}

struct AddObjectFilesSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let object: PersonalObject
    @State private var search = ""
    @State private var managedOnly = false
    @State private var candidates: [LibraryFile] = []
    @State private var selected: Set<String> = []
    @State private var saving = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("为「\(object.name)」添加已有资料").font(.title2.bold())
            HStack {
                TextField("搜索名称或路径", text: $search)
                Toggle("仅已托管", isOn: $managedOnly).toggleStyle(.checkbox)
            }
            Text("可按住 ⌘ 选择多份资料。关联不会更改原文件或照片。")
                .font(.caption).foregroundStyle(.secondary)
            Table(candidates, selection: $selected) {
                TableColumn("名称", value: \.name)
                TableColumn("来源", value: \.sourceName).width(min: 70, ideal: 100)
            }
            if let loadError { Text(loadError).foregroundStyle(.orange).font(.callout) }
            HStack {
                Text("已选择 \(selected.count) 份").foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "正在关联…" : "关联所选资料") {
                    saving = true
                    Task {
                        if await model.linkItems(Array(selected), to: object.id) { dismiss() }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(selected.isEmpty || saving)
            }
        }.padding(24).frame(width: 620, height: 440)
            .task(id: "\(search)|\(managedOnly)") {
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    let result = try await model.availableFiles(search: search, managedOnly: managedOnly)
                    guard !Task.isCancelled else { return }
                    candidates = result
                    loadError = nil
                } catch is CancellationError { }
                catch { loadError = "无法读取资料，请重试。" }
            }
    }
}
