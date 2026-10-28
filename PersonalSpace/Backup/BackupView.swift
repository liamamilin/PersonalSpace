import AppKit
import SwiftUI

struct RestoredLibrary: Identifiable, Sendable {
    var id = UUID()
    let root: URL
    let files: [LibraryFile]
}

struct BackupView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var presentedLibrary: RestoredLibrary?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("备份与恢复").font(.title2.bold())
                Text("导出资料库和托管凭证，在独立测试资料库中验证恢复结果。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
            Form {
                Section {
                    Text("备份包含资料库、已保存的正文索引、对象与事务关联，以及托管副本。")
                    Text("导出的数据库和文件为明文，可能包含个人资料。请选择自己信任的位置保存。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("来源文件夹中的原件和系统照片图库中的照片不包含在备份中。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("导出备份…", systemImage: "square.and.arrow.up") { model.exportBackup() }
                        .disabled(model.backupBusy || model.storageUnavailable)
                        .accessibilityIdentifier("backup-export")
                } header: {
                    Text("导出备份")
                }
                Section {
                    Text("选择一份备份，完整校验后恢复到应用内全新独立测试资料库。当前使用的资料库保持不变。")
                    Text("恢复不会使用原来源的授权书签，不会自动重新安排系统提醒。恢复窗口可直接预览和打开已恢复的托管副本。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("选择备份并恢复…", systemImage: "square.and.arrow.down") { model.restoreBackup() }
                        .disabled(model.backupBusy)
                        .accessibilityIdentifier("backup-restore")
                } header: {
                    Text("恢复到独立测试资料库")
                }
                if let library = model.restoredLibrary {
                    Section("恢复结果") {
                        Label("独立恢复资料库已准备好", systemImage: "externaldrive.badge.checkmark")
                        Text("\(library.files.count) 份资料记录 · \(library.files.filter { $0.managedCopyPath != nil && !$0.isPhoto }.count) 份托管副本")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(library.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("查看恢复资料", systemImage: "doc.on.doc") { presentedLibrary = library }
                            .disabled(model.backupBusy)
                            .accessibilityIdentifier("backup-open-restored-library")
                    }
                }
            }.formStyle(.grouped)
            if model.backupBusy || model.backupMessage != nil {
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    if model.backupBusy { ProgressView().controlSize(.small) }
                    if let message = model.backupMessage {
                        Text(message).font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("正在处理备份资料…").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(20)
            }
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 440, idealHeight: 560)
        .sheet(item: $presentedLibrary) { library in RestoredLibraryView(library: library) }
    }
}

struct RestoredLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    let library: RestoredLibrary
    @State private var search = ""
    @State private var selectedFileID: String?
    @State private var sortOrder = [KeyPathComparator(\LibraryFile.name)]
    @State private var previewURL: URL?
    @State private var previewError: String?
    @State private var actionError: String?
    @State private var fullPreview: RestoredCopyPreviewItem?

    init(library: RestoredLibrary) {
        self.library = library
        _selectedFileID = State(initialValue: library.files.first(where: { $0.managedCopyPath != nil && !$0.isPhoto })?.id
            ?? library.files.first?.id)
    }

    private var filtered: [LibraryFile] {
        library.files.filter {
            search.isEmpty || $0.name.localizedStandardContains(search)
                || $0.relativePath.localizedStandardContains(search)
                || $0.sourceName.localizedStandardContains(search)
        }.sorted(using: sortOrder)
    }

    private var selectedFile: LibraryFile? { library.files.first { $0.id == selectedFileID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("独立恢复资料库").font(.title2.bold())
                    Text("从已校验的恢复目录中查看托管副本；当前资料库继续保持原状。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack {
                TextField("搜索恢复资料的名称或原路径", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("restored-library-search")
                Text("\(filtered.count) 份资料").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            HSplitView {
                Group {
                    if library.files.isEmpty {
                        ContentUnavailableView("备份中没有资料记录", systemImage: "tray")
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        fileTable
                    }
                }.frame(minWidth: 290, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                detail.frame(minWidth: 290, idealWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Text("此窗口仅访问恢复目录中的 Vault。原来源书签不使用，系统照片和来源原件需重新授权后另行访问。通知不会自动重新排期。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 500, idealHeight: 660)
        .task(id: selectedFileID) { preparePreview() }
        .sheet(item: $fullPreview) { item in RestoredCopyPreview(item: item) }
    }

    private var fileTable: some View {
        Table(filtered, selection: $selectedFileID, sortOrder: $sortOrder) {
            TableColumn("资料", value: \.name) { file in
                Label(file.name, systemImage: file.isPhoto ? "photo" : "doc").frame(height: 32)
            }.width(min: 150, ideal: 240)
            TableColumn("备份内容") { file in
                Text(file.isPhoto ? "照片关联" : file.managedCopyPath == nil ? "来源索引" : "托管副本")
                    .font(.callout).foregroundStyle(.secondary)
            }.width(min: 75, ideal: 95)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let file = library.files.first(where: { $0.id == id }),
               file.managedCopyPath != nil, !file.isPhoto {
                Button("系统预览托管副本") { showPreview(file) }
                Button("打开托管副本") { openCopy(file) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let file = library.files.first(where: { $0.id == id }) { openCopy(file) }
        }
        .onKeyPress(.space) {
            guard let file = selectedFile, previewURL != nil else { return .ignored }
            showPreview(file)
            return .handled
        }
    }

    @ViewBuilder private var detail: some View {
        if let file = selectedFile {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(file.name).font(.headline).textSelection(.enabled)
                    Text(file.isPhoto ? "系统照片关联记录" : file.kind + " · " + file.size)
                        .font(.callout).foregroundStyle(.secondary)
                    if let previewURL {
                        Label("恢复的托管副本", systemImage: "externaldrive.badge.checkmark")
                            .font(.caption).foregroundStyle(.secondary)
                        SystemPreview(url: previewURL).frame(height: 250)
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Button("系统预览") { showPreview(file) }
                                Button("打开托管副本") { openCopy(file) }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Button("系统预览") { showPreview(file) }
                                Button("打开托管副本") { openCopy(file) }
                            }
                        }.controlSize(.small)
                    } else {
                        ContentUnavailableView(file.isPhoto ? "照片原图不在备份中" : "此条目没有可用的托管副本",
                            systemImage: file.isPhoto ? "photo" : "doc.badge.exclamationmark",
                            description: Text(previewError ?? "备份保留了资料索引与关联信息，来源原件不包含在备份中。"))
                            .frame(minHeight: 180)
                    }
                    if let actionError { Text(actionError).font(.callout).foregroundStyle(.orange) }
                    Divider()
                    property("原来源名称", value: file.sourceName)
                    if !file.isPhoto { property("原相对路径", value: file.relativePath) }
                    if let date = file.managedAt {
                        property("副本保存日期", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        } else {
            ContentUnavailableView("选择一份恢复资料", systemImage: "doc.text.magnifyingglass",
                description: Text("检查托管副本，或查看未包含原件的索引记录。"))
        }
    }

    private func copyURL(for file: LibraryFile) throws -> URL {
        guard !file.isPhoto, let relativePath = file.managedCopyPath else { throw RestoredCopyError.noCopy }
        let vault = library.root.appendingPathComponent("Vault", isDirectory: true)
        return try ManagedFileStore(root: vault).url(for: relativePath)
    }

    private func preparePreview() {
        previewURL = nil
        previewError = nil
        actionError = nil
        guard let file = selectedFile else { return }
        if file.isPhoto {
            previewError = "这里只保留照片的名称和关联信息。要查看原图，请回到照片图库重新连接授权。"
        } else if file.managedCopyPath == nil {
            previewError = "这份资料只保存了来源索引，备份中没有原件。请回到活动资料库重新选择原来源文件夹。"
        } else {
            do { previewURL = try copyURL(for: file) }
            catch { previewError = "恢复的托管副本已不可用，或其位置无法验证。请重新校验并恢复备份。" }
        }
    }

    private func openCopy(_ file: LibraryFile) {
        selectedFileID = file.id
        do {
            let url = try copyURL(for: file)
            actionError = NSWorkspace.shared.open(url) ? nil : "默认应用未能打开此托管副本，可以尝试系统预览。"
        } catch {
            actionError = "无法打开：此条目没有可验证的恢复托管副本。原来源和系统照片不从此窗口访问。"
        }
    }

    private func showPreview(_ file: LibraryFile) {
        selectedFileID = file.id
        do {
            fullPreview = RestoredCopyPreviewItem(name: file.name, url: try copyURL(for: file))
            actionError = nil
        } catch { actionError = "系统预览无法读取此恢复托管副本，请重新校验并恢复。" }
    }

    private func property(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum RestoredCopyError: Error { case noCopy }

private struct RestoredCopyPreviewItem: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
}

private struct RestoredCopyPreview: View {
    @Environment(\.dismiss) private var dismiss
    let item: RestoredCopyPreviewItem

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.name + " · 恢复的托管副本").font(.headline).lineLimit(1)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            SystemPreview(url: item.url).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 560, idealWidth: 760, minHeight: 480, idealHeight: 640)
    }
}
