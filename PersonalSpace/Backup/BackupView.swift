import AppKit
import SwiftUI

struct RestoredLibrary: Identifiable, Sendable {
    var id = UUID()
    let root: URL
    let files: [LibraryFile]
    var title = "备份预览"
    var temporary = false
}

struct BackupView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var presentedLibrary: RestoredLibrary?
    @State private var switchTarget: LibraryLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("备份与恢复").font(.title2.weight(.semibold)).padding(.horizontal, 24).padding(.top, 20)
            Form {
                if let current = model.libraryLocation {
                    Section("正在使用") {
                        Text(current.title).font(.headline).textSelection(.enabled)
                        if let origin = current.origin {
                            Text("来自 " + origin.date.formatted(date: .abbreviated, time: .shortened) + " 的备份")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let pending = model.pendingLibrary {
                            Label("下次启动：" + pending.title, systemImage: "arrow.right.circle")
                            Text("当前窗口继续使用本资料库，退出重开后切换。")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("退出以启用") { NSApp.terminate(nil) }.disabled(model.backupBusy)
                                Button("取消下次启动切换") { model.switchLibraryAfterRestart(to: current) }
                                    .disabled(model.backupBusy)
                            }
                        }
                    }
                }
                Section {
                    LabeledContent {
                        Button("导出备份…", systemImage: "square.and.arrow.up") { model.exportBackup() }
                            .disabled(model.backupBusy || model.storageUnavailable).accessibilityIdentifier("backup-export")
                    } label: { Text("保存当前资料库与托管凭证") }
                    LabeledContent {
                        Button("验证并查看备份…", systemImage: "checkmark.shield") { model.restoreBackup() }
                            .disabled(model.backupBusy).accessibilityIdentifier("backup-restore")
                    } label: { Text("检查备份完整性") }
                    LabeledContent {
                        Button("恢复并启用此备份…", systemImage: "arrow.down.doc") { model.chooseBackupToActivate() }
                            .disabled(model.backupBusy || !model.canSwitchLibraries).accessibilityIdentifier("backup-activate")
                    } label: { Text("下次启动使用恢复资料库") }
                } header: { Text("备份操作") } footer: {
                    Text("包含资料索引、已保存正文、对象、事务、行动与托管凭证；不包含外部原件和照片原图。备份未加密，请妥善保管。")
                }
                if let verified = model.verifiedBackup {
                    Section("已验证的备份") {
                        Text(verified.url.lastPathComponent).font(.headline).textSelection(.enabled)
                        Text(verified.summary.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(verified.summary.itemCount) 份资料 · \(verified.summary.matterCount) 个事务 · \(verified.summary.managedCount) 份托管凭证")
                            .font(.callout)
                        HStack {
                            Button("预览托管凭证", systemImage: "eye") { model.previewVerifiedBackup(verified) }
                                .disabled(model.backupBusy || verified.summary.managedCount == 0)
                            Button("使用此备份恢复…") { model.backupCandidate = verified }
                                .disabled(model.backupBusy || !model.canSwitchLibraries)
                        }
                        Text("验证不创建永久副本，临时预览在关闭后清理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let current = model.libraryLocation {
                    if let old = model.retainedLibrary, old.id != current.id {
                        Section("保留的旧资料库") {
                            Text(old.title).textSelection(.enabled)
                            HStack {
                                Button("查看保留资料库") { model.previewRetainedLibrary(old) }
                                Button("下次启动切回此资料库") { switchTarget = old }
                            }.disabled(model.backupBusy)
                        }
                    }
                    if current.id != "original", model.retainedLibrary?.id != "original", let original = model.originalLibrary {
                        Button("下次启动切回原始资料库") { switchTarget = original }.disabled(model.backupBusy)
                    }
                }
            }.formStyle(.grouped)
            if model.backupBusy || model.backupMessage != nil {
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    if model.backupBusy { ProgressView().controlSize(.small) }
                    Text(model.backupMessage ?? "正在处理备份…").font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }.padding(16)
            }
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 440, idealHeight: 560)
        .sheet(item: $presentedLibrary, onDismiss: { model.finishBackupPreview() }) { library in
            RestoredLibraryView(library: library)
        }
        .sheet(item: $model.backupCandidate) { candidate in BackupActivationSheet(candidate: candidate) }
        .onChange(of: model.restoredLibrary?.id) { presentedLibrary = model.restoredLibrary }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.finishBackupPreview()
        }
        .confirmationDialog("下次启动切换资料库？", isPresented: Binding(get: { switchTarget != nil }, set: {
            if !$0 { switchTarget = nil }
        }), presenting: switchTarget) { target in
            Button("切换到「" + target.title + "」") { model.switchLibraryAfterRestart(to: target) }
            Button("取消", role: .cancel) { }
        } message: { target in
            Text("下次启动使用「" + target.title + "」，当前资料库仍保留。切换不会取消旧资料库的系统提醒，新资料库也不会自动恢复全部通知。提醒状态以当前设备实际待发送请求为准。")
        }
        .task { model.refreshLibrarySelection() }
    }
}

private struct BackupActivationSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let candidate: BackupCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("恢复并启用备份").font(.title2.weight(.semibold)).padding(20)
            Form {
                Section("要启用的备份") {
                    LabeledContent("备份", value: candidate.url.lastPathComponent)
                    LabeledContent("日期", value: candidate.summary.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("资料 / 事务 / 托管凭证", value: "\(candidate.summary.itemCount) / \(candidate.summary.matterCount) / \(candidate.summary.managedCount)")
                }
                Section("恢复范围") {
                    Text("恢复资料索引、正文、对象、事务、事实、行动及 Vault 凭证。下次启动启用，当前资料库不覆盖并可切回。")
                    Text("外部原件和照片原图不在备份内。文件夹需重新授权，可选新路径；照片需检查当前设备权限与标识。")
                }
            }.formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("切换不取消旧资料库提醒，也不自动恢复新资料库通知；状态以系统实际待发送请求为准。备份未加密，请妥善保管。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("恢复并在下次启动启用") { model.activateBackup(candidate); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }.frame(width: 560, height: 540)
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
                    Text(library.title).font(.title2.bold())
                    Text(library.temporary ? "临时预览，关闭后清理。当前资料库与原备份保持不变。" : "查看保留资料库的托管凭证，当前资料库保持不变。")
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
            Text("此窗口仅预览托管凭证，不使用原来源书签，不连接照片，也不安排系统提醒。")
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
                Label(file.name, systemImage: file.isPhoto ? "photo" : "doc").frame(height: 28)
            }.width(min: 150, ideal: 240)
            TableColumn("备份内容") { file in
                Text(file.isPhoto ? "照片关联" : file.managedCopyPath == nil ? "来源索引" : "托管副本")
                    .font(.callout).foregroundStyle(.secondary)
            }.width(min: 75, ideal: 95)
        }
        .alternatingRowBackgrounds(.disabled)
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
