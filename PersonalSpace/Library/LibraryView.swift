import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var showInspector = true
    @State private var sortOrder = [KeyPathComparator(\LibraryFile.name)]
    @FocusState private var searchFocused: Bool

    private var queryKey: String {
        "\(model.search)|\(model.selectedSourceID)|\(model.sort.rawValue)|\(model.ascending)|\(model.limit)"
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding<String?>(get: { model.selectedSourceID },
                    set: { model.selectedSourceID = $0 ?? "all" })) {
                    Section("资料库") {
                        Label("所有资料", systemImage: "tray.full").tag("all")
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
                if let message = model.errorMessage {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle").font(.callout)
                        Spacer()
                        Button("关闭", systemImage: "xmark") { model.errorMessage = nil }.labelStyle(.iconOnly)
                    }
                    .padding(12).background(.orange.opacity(0.12))
                }
                if let source = model.sources.first(where: { $0.id == model.selectedSourceID }), let error = source.lastError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        Spacer()
                        Button("重新授权") { model.addFolders(replacing: source) }
                            .disabled(model.scanning[source.id] != nil)
                    }.padding(12).background(.orange.opacity(0.1))
                }
                content
                Divider()
                HStack(spacing: 8) {
                    if model.isScanning {
                        ProgressView().controlSize(.mini)
                        Text("扫描中 · 已发现 \(model.scanning.values.reduce(0, +)) 个文件")
                    } else {
                        Text("\(model.total) 份资料")
                        if model.selectedFile != nil { Text("· 已选择 1 份") }
                    }
                    Spacer()
                    if model.files.count < model.total {
                        Button("显示更多") { model.limit += 500 }.buttonStyle(.link)
                    }
                    Text("本地索引").foregroundStyle(.tertiary)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .navigationTitle(model.sources.first(where: { $0.id == model.selectedSourceID })?.name ?? "资料库")
            .inspector(isPresented: $showInspector) {
                FileDetailView().inspectorColumnWidth(min: 300, ideal: 340, max: 440)
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "搜索名称或路径")
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItemGroup {
                Button("添加文件夹", systemImage: "folder.badge.plus") { model.addFolders() }
                    .disabled(model.storageUnavailable)
                    .help("添加要索引的文件夹")
                Button("刷新", systemImage: "arrow.clockwise") {
                    if let source = model.sources.first(where: { $0.id == model.selectedSourceID }) {
                        model.refresh(source)
                    } else { model.refreshAll() }
                }
                .disabled(model.sources.isEmpty || model.isScanning)
                .help("刷新所选来源或所有来源（⌘R）")
                Menu {
                    Picker("排序", selection: $model.sort) {
                        ForEach(FileSort.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("升序", isOn: $model.ascending)
                } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
                Button("详情", systemImage: "sidebar.right") { showInspector.toggle() }
                    .help("显示或隐藏文件详情")
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .task { await model.start() }
        .task(id: queryKey) {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await model.reload()
        }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onChange(of: model.search) { model.limit = 500 }
        .onChange(of: model.selectedSourceID) { model.limit = 500 }
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
    }

    @ViewBuilder private var content: some View {
        if model.sources.isEmpty {
            ContentUnavailableView {
                Label("把散落的个人资料放到一个入口", systemImage: "folder.badge.plus")
            } description: {
                Text("文件保留在原位置，仅建立本地索引。\n添加你希望查找的文件夹，开始使用资料库。")
            } actions: {
                Button("添加文件夹") { model.addFolders() }
                    .buttonStyle(.borderedProminent).disabled(model.storageUnavailable)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.files.isEmpty {
            ContentUnavailableView {
                Label(model.search.isEmpty ? (model.isScanning ? "正在查找文件" : "这个来源还没有文件") : "没有找到相关资料",
                      systemImage: model.search.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass")
            } description: {
                Text(model.search.isEmpty ? "仅索引普通文件，跳过隐藏文件、目录包和符号链接。" : "试试文件名或路径中的其它关键词。")
            } actions: {
                if !model.search.isEmpty { Button("清除搜索") { model.search = "" } }
                else { Button("刷新来源") { model.refreshAll() }.disabled(model.isScanning) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.files, selection: $model.selectedFileID, sortOrder: $sortOrder) {
                TableColumn("名称", value: \.name) { file in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(file.typeIdentifier) ?? .data))
                            .resizable().frame(width: 20, height: 20)
                        Text(file.name).lineLimit(1)
                        if !file.isAvailable || file.sourceError != nil {
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
                    Button("打开原件") { model.selectedFileID = id; model.openSelected() }
                    Button("在 Finder 中显示") { model.selectedFileID = id; model.revealSelected() }
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
