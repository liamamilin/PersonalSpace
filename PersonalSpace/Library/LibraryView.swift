import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var showInspector = true
    @State private var compactWindow = false
    @State private var showCompactInspector = false
    @State private var dropTargeted = false
    @State private var sortOrder = [KeyPathComparator(\LibraryFile.name)]
    @FocusState private var searchFocused: Bool

    private var queryKey: String {
        "\(model.search)|\(model.searchBody)|\(model.selectedSourceID)|\(model.sort.rawValue)|\(model.ascending)|\(model.limit)"
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding<String?>(get: {
                    model.currentObjectID == nil ? model.selectedSourceID : "objects"
                }, set: {
                    let destination = $0 ?? "all"
                    if ["objects", "matters", "actions"].contains(destination) || !model.isFileList || model.currentObjectID != nil { model.search = "" }
                    model.selectedFileID = nil
                    model.selectedSourceID = destination
                })) {
                    Section("资料库") {
                        HStack {
                            Label("待整理", systemImage: "tray.and.arrow.down")
                            Spacer()
                            if model.inboxCount > 0 { Text(model.inboxCount, format: .number).foregroundStyle(.secondary) }
                        }.tag("inbox")
                        Label("所有资料", systemImage: "tray.full").tag("all")
                        Label("已托管", systemImage: "externaldrive.badge.checkmark").tag("managed")
                        Label("照片图库", systemImage: "photo.on.rectangle").tag(PhotoLibraryController.sourceID)
                    }
                    Section("个人对象") {
                        Label("个人对象", systemImage: "desktopcomputer").tag("objects")
                    }
                    Section("跟进") {
                        Label("事务", systemImage: "doc.text").tag("matters")
                        Label("待办", systemImage: "checklist").tag("actions")
                    }
                    Section("已授权来源") {
                        ForEach(model.sources) { source in
                            HStack(spacing: 8) {
                                Image(systemName: source.lastError == nil ? "folder" : "folder.badge.questionmark")
                                Text(source.name).lineLimit(1)
                                Spacer(minLength: 0)
                                if model.scanning[source.id] != nil {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Text(source.fileCount, format: .number).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(source.id)
                            .help(source.path)
                            .contextMenu {
                                Button("刷新来源") { model.refresh(source) }.disabled(model.scanning[source.id] != nil)
                                Button("重新授权") { model.addFolders(replacing: source) }
                                    .disabled(model.scanning[source.id] != nil)
                            }
                        }
                        Button("添加文件夹", systemImage: "folder.badge.plus") { model.addFolders() }
                            .disabled(model.storageUnavailable).buttonStyle(.plain)
                    }
                }.listStyle(.sidebar)
                Divider()
                HStack {
                    SettingsLink { Label("来源设置", systemImage: "gearshape") }
                        .buttonStyle(.plain)
                    Spacer()
                }.padding(16)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if model.isImporting || model.importMessage != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if model.isImporting {
                                ProgressView().controlSize(.small)
                                Text(model.importingTotal == 0 ? "正在读取拖入的文件…" : "正在收纳 · \(model.importCompleted) / \(model.importingTotal)")
                            } else {
                                Label(model.importMessage ?? "", systemImage: model.importFailures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                                Spacer()
                                Button("关闭收纳结果", systemImage: "xmark") { model.importMessage = nil; model.importFailures = [] }
                                    .labelStyle(.iconOnly)
                            }
                        }
                        if !model.importFailures.isEmpty {
                            DisclosureGroup("未收纳的文件（\(model.importFailures.count)）") {
                                ForEach(Array(model.importFailures.enumerated()), id: \.offset) { _, failure in
                                    Text(failure).font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                    }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5))
                }
                if let message = model.errorMessage {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle").font(.callout)
                        Spacer()
                        Button("关闭", systemImage: "xmark") { model.errorMessage = nil }.labelStyle(.iconOnly)
                    }
                    .padding(12).background(.orange.opacity(0.12))
                }
                if model.isInbox {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("快速收纳").font(.headline)
                            Text("从 Finder 拖入文件，或选择文件收纳。关联对象或事务后移出待整理，副本仍保留在资料库。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("收纳文件…", systemImage: "tray.and.arrow.down") { model.chooseImportFiles() }
                            .disabled(model.storageUnavailable || model.isImporting)
                    }.padding(16)
                    Divider()
                }
                if let source = model.sources.first(where: { $0.id == model.selectedSourceID }), let error = source.lastError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        Spacer()
                        Button("重新授权") { model.addFolders(replacing: source) }
                            .disabled(model.scanning[source.id] != nil)
                    }.padding(12).background(.orange.opacity(0.1))
                }
                if let object = model.selectedObject, model.currentObjectID != nil {
                    HStack(spacing: 12) {
                        Button("个人对象", systemImage: "chevron.left") {
                            model.selectedSourceID = "objects"
                            model.selectedFileID = nil
                            model.search = ""
                        }.buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(object.name).font(.headline)
                            if !object.notes.isEmpty {
                                Text(object.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("编辑", systemImage: "pencil") { model.editObject(object) }
                        Button("添加已有资料", systemImage: "link.badge.plus") { model.showFilePicker = true }
                    }.padding(16)
                    Divider()
                }
                if model.isObjectsList { ObjectsView() }
                else if model.isMattersList { MattersView() }
                else if model.isActionsList { ActionsView() }
                else if model.isPhotosList { PhotosLibraryView() }
                else { content }
                Divider()
                HStack(spacing: 8) {
                    if model.isScanning {
                        ProgressView().controlSize(.mini)
                        Text("扫描中 · 已发现 \(model.scanning.values.reduce(0, +)) 个文件")
                    } else {
                        Text(model.isObjectsList ? "\(model.objects.count) 个个人对象" : model.isMattersList ? "共 \(model.matters.count) 个事务" : model.isActionsList ? "\(model.actions.count) 项行动" : "\(model.total) 份资料")
                        if model.isFileList && model.selectedFile != nil { Text("· 已选择 1 份") }
                    }
                    Spacer()
                    if model.isFileList && model.files.count < model.total {
                        Button("显示更多") { model.limit += 500 }.buttonStyle(.link)
                    }
                    Text("本地索引").foregroundStyle(.tertiary)
                    if model.isFileList && model.searchBody { Text("· 含已允许正文") }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .navigationTitle(navigationTitle)
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                model.receiveDroppedFiles(providers)
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 3)
                        .padding(4).allowsHitTesting(false)
                }
            }
            .inspector(isPresented: Binding(get: { showInspector && !compactWindow }, set: { showInspector = $0 })) {
                inspectorContent.inspectorColumnWidth(min: 300, ideal: 340, max: 440)
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: model.isFileList ? (model.searchBody ? "搜索名称、路径或已允许的正文" : "搜索名称或路径") : "搜索名称或备注")
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItemGroup {
                Button("收纳文件", systemImage: "tray.and.arrow.down") { model.chooseImportFiles() }
                    .disabled(model.storageUnavailable || model.isImporting)
                    .help("复制文件到待整理（⇧⌘I），也可从 Finder 拖入")
                Menu {
                    Button("创建个人对象") { model.createObject() }
                    Menu("创建事务") {
                        ForEach(MatterKind.allCases) { kind in
                            Button("创建" + kind.title) { model.createMatter(kind: kind) }
                        }
                    }
                } label: { Label("新建", systemImage: "plus") }
                    .disabled(model.storageUnavailable)
                Button("添加文件夹", systemImage: "folder.badge.plus") { model.addFolders() }
                    .disabled(model.storageUnavailable)
                    .help("添加要索引的文件夹")
                Menu {
                    Toggle("搜索已允许保存的正文", isOn: $model.searchBody)
                } label: { Label("搜索范围", systemImage: model.searchBody ? "doc.text.magnifyingglass" : "magnifyingglass") }
                    .disabled(!model.isFileList)
                    .help(model.searchBody ? "搜索名称、路径及已允许的正文" : "仅搜索名称与路径")
                Button("刷新", systemImage: "arrow.clockwise") {
                    if let source = model.sources.first(where: { $0.id == model.selectedSourceID }) {
                        model.refresh(source)
                    } else { model.refreshAll() }
                }
                .disabled((model.sources.isEmpty && !model.isPhotosList) || model.isScanning)
                .help("刷新所选来源或所有来源（⌘R）")
                Menu {
                    Picker("排序", selection: $model.sort) {
                        ForEach(FileSort.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("升序", isOn: $model.ascending)
                } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
                    .disabled(!model.isFileList)
                Button("详情", systemImage: "sidebar.right") {
                    if compactWindow { showCompactInspector.toggle() }
                    else { showInspector.toggle() }
                }
                    .popover(isPresented: $showCompactInspector) {
                        inspectorContent.frame(width: 360, height: 540)
                    }
                    .help("显示或隐藏文件详情")
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .onGeometryChange(for: Bool.self, of: { $0.size.width < 1_000 }) { compact in
            compactWindow = compact
            if !compact { showCompactInspector = false }
        }
        .task {
            model.openLibraryWindow = { openWindow(id: "library") }
            await model.start()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task {
                    await model.refreshReminderStatus()
                    await model.refreshPhotosAuthorization()
                    await model.reload()
                }
            }
        }
        .task(id: queryKey) {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await model.reload()
        }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onChange(of: model.search) { model.limit = 500 }
        .onChange(of: model.selectedSourceID) { model.limit = 500; showCompactInspector = false }
        .onChange(of: sortOrder) {
            guard let first = sortOrder.first else { return }
            switch first.keyPath {
            case \LibraryFile.kind: model.sort = .kind
            case \LibraryFile.modifiedSortDate: model.sort = .modified
            case \LibraryFile.bytes: model.sort = .size
            case \LibraryFile.sourceName: model.sort = .source
            default: model.sort = .name
            }
            model.ascending = first.order == .forward
        }
        .sheet(isPresented: $model.showQuickLook) { QuickLookSheet().environmentObject(model) }
        .sheet(isPresented: $model.showPhotoPreview, onDismiss: { model.photoPreviewImage = nil }) {
            PhotoPreviewSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showObjectEditor) {
            ObjectEditorView(object: model.objectBeingEdited).environmentObject(model)
        }
        .sheet(isPresented: $model.showLinkSheet) { LinkToObjectSheet().environmentObject(model) }
        .sheet(isPresented: $model.showFilePicker) {
            if let object = model.selectedObject { AddObjectFilesSheet(object: object).environmentObject(model) }
        }
        .sheet(isPresented: $model.showMatterEditor) {
            MatterEditorView(draft: model.matterDraft).environmentObject(model)
        }
    }

    @ViewBuilder private var inspectorContent: some View {
        if model.isObjectsList { ObjectInfoView() }
        else if model.isMattersList || model.isActionsList { MatterDetailView() }
        else { FileDetailView() }
    }

    private var navigationTitle: String {
        if model.isObjectsList { return "个人对象" }
        if model.isMattersList { return "事务" }
        if model.isActionsList { return "待办" }
        if model.isPhotosList { return "照片图库" }
        if model.isInbox { return "待整理" }
        if model.currentObjectID != nil { return model.selectedObject?.name ?? "个人对象" }
        if model.selectedSourceID == "managed" { return "已托管" }
        return model.sources.first(where: { $0.id == model.selectedSourceID })?.name ?? "资料库"
    }

    @ViewBuilder private var content: some View {
        if model.isInbox && model.files.isEmpty {
            ContentUnavailableView {
                Label(model.search.isEmpty ? "收纳文件，稍后整理" : "没有找到待整理资料", systemImage: "tray.and.arrow.down")
            } description: {
                Text(model.search.isEmpty ? "把一份或多份文件从 Finder 拖到这里。\n托管副本可独立使用，原文件保持不变。" : "试试其它关键词，或在「所有资料」中查找已整理的文件。")
            } actions: {
                if model.search.isEmpty {
                    Button("收纳文件…") { model.chooseImportFiles() }.buttonStyle(.borderedProminent)
                        .disabled(model.storageUnavailable || model.isImporting)
                } else { Button("清除搜索") { model.search = "" } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sources.isEmpty && model.total == 0 && model.currentObjectID == nil && model.selectedSourceID != "managed" {
            ContentUnavailableView {
                Label("把散落的个人资料放到一个入口", systemImage: "folder.badge.plus")
            } description: {
                Text("文件保留在原位置，仅建立本地索引。\n添加你希望查找的文件夹，开始使用资料库。")
            } actions: {
                Button("收纳文件…") { model.chooseImportFiles() }
                    .disabled(model.storageUnavailable || model.isImporting)
                Button("添加文件夹") { model.addFolders() }
                    .buttonStyle(.borderedProminent).disabled(model.storageUnavailable)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.files.isEmpty {
            ContentUnavailableView {
                Label(model.search.isEmpty ? (model.isScanning ? "正在查找文件" : model.currentObjectID != nil ? "还没有关联资料" : model.selectedSourceID == "managed" ? "还没有托管副本" : "这个来源还没有文件") : "没有找到相关资料",
                      systemImage: model.search.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass")
            } description: {
                Text(model.search.isEmpty ? (model.currentObjectID != nil ? "添加已有资料，把来自不同位置的凭证关联到这个对象。" : model.selectedSourceID == "managed" ? "选择一份资料，在详情中点击「保存副本到资料库」。" : "仅索引普通文件，跳过隐藏文件、目录包和符号链接。") : model.searchBody ? "试试名称、路径或已允许正文中的其它关键词。" : "试试文件名或路径中的其它关键词。")
            } actions: {
                if !model.search.isEmpty { Button("清除搜索") { model.search = "" } }
                else if model.currentObjectID != nil {
                    Button("添加已有资料") { model.showFilePicker = true }
                } else { Button("刷新来源") { model.refreshAll() }.disabled(model.isScanning) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.files, selection: $model.selectedFileID, sortOrder: $sortOrder) {
                TableColumn("名称", value: \.name) { file in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(file.typeIdentifier) ?? .data))
                            .resizable().frame(width: 20, height: 20)
                        Text(file.name).lineLimit(1)
                        if file.managedCopyPath != nil {
                            Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(.secondary)
                                .help("已保存托管副本")
                        }
                        if (!file.isAvailable && !file.isImported) || file.sourceError != nil {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                .help(file.sourceError ?? "原位置已不可用")
                        }
                    }.frame(height: 30).help(file.relativePath)
                }.width(min: 170, ideal: 240)
                TableColumn("类型", value: \.kind) { file in
                    Text(file.kind).foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 70, ideal: 90)
                TableColumn("修改日期", value: \.modifiedSortDate) { file in
                    Text(file.modifiedAt?.formatted(date: .numeric, time: .omitted) ?? "—")
                        .foregroundStyle(.secondary)
                }.width(min: 80, ideal: 100)
                TableColumn("大小", value: \.bytes) { file in
                    Text(file.size).foregroundStyle(.secondary)
                }.width(min: 60, ideal: 70)
                TableColumn("来源", value: \.sourceName) { file in
                    Text(file.sourceName).foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 65, ideal: 90)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    Button("系统预览") { model.selectedFileID = id; model.quickLook() }
                    Button("打开可用文件") { model.selectedFileID = id; model.openSelected() }
                    Button("关联到对象…") { model.selectedFileID = id; model.showLinkSheet = true }
                    Menu("创建事务") {
                        ForEach(MatterKind.allCases) { kind in
                            Button("创建" + kind.title) { model.selectedFileID = id; model.createMatter(kind: kind) }
                        }
                    }
                    if let objectID = model.currentObjectID {
                        Button("解除与此对象的关联") { Task { await model.unlink(id, from: objectID) } }
                    }
                    if model.files.first(where: { $0.id == id })?.isPhoto != true {
                        Button(model.files.first(where: { $0.id == id })?.isImported == true ? "在 Finder 中显示副本" : "在 Finder 中显示") {
                            model.selectedFileID = id; model.revealSelected()
                        }
                    }
                }
            } primaryAction: { ids in
                model.selectedFileID = ids.first
                model.openSelected()
            }
            .onKeyPress(.space) {
                guard model.selectedFileID != nil else { return .ignored }
                model.quickLook()
                return .handled
            }
            .onKeyPress(.return) {
                guard model.selectedFileID != nil else { return .ignored }
                model.openSelected()
                return .handled
            }
        }
    }
}
