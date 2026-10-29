import SwiftUI
import Quartz

struct SystemPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        // SwiftUI can move a preview between Inspector and popover windows.
        // Only dismantling owns close(); a closed QLPreviewView cannot be reused.
        view.shouldCloseWithWindow = false
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct FileDetailView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        Group {
            if let file = model.selectedFile, file.isPhoto {
                PhotoDetailView(file: file)
            } else if let file = model.selectedFile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).font(.headline).textSelection(.enabled)
                            Text(file.kind + " · " + file.size + " · " + file.sourceName)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        fileActions(file)
                        preview
                        HStack {
                            Button("关联对象…", systemImage: "link") { model.showLinkSheet = true }
                            Menu("创建事务", systemImage: "doc.badge.plus") {
                                ForEach(MatterKind.allCases) { kind in
                                    Button("创建" + kind.title) { model.createMatter(kind: kind) }
                                }
                            }
                        }.controlSize(.small)
                        if !model.linkedObjects.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("关联对象").font(.caption).foregroundStyle(.secondary)
                                ForEach(model.linkedObjects) { object in
                                    HStack {
                                        Button(object.name) { model.showObject(object.id) }.buttonStyle(.link)
                                        Spacer()
                                        Menu {
                                            Button("解除与此对象的关联") {
                                                Task { await model.unlink(file.id, from: object.id) }
                                            }
                                        } label: { Image(systemName: "ellipsis") }
                                            .menuStyle(.borderlessButton).fixedSize()
                                            .accessibilityLabel("「\(object.name)」的关联操作")
                                    }
                                }
                            }
                        }
                        if let error = model.managedError ?? model.originalError, !file.isImported {
                            VStack(alignment: .leading, spacing: 8) {
                                if model.previewURL != nil {
                                    Label(error, systemImage: "exclamationmark.triangle")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                if model.originalURL == nil, let source = model.sources.first(where: { $0.id == file.sourceID }) {
                                    Button("重新授权来源") { model.addFolders(replacing: source) }
                                        .controlSize(.small).disabled(model.scanning[source.id] != nil)
                                }
                            }
                        } else if let error = model.managedError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Label(file.managedCopyPath != nil ? "已保存托管副本" : "文件保留在原位置",
                                  systemImage: file.managedCopyPath != nil ? "externaldrive.badge.checkmark" : "folder")
                                .font(.callout)
                            Text(file.isImported ? "快速收纳只复制文件，原文件保持不变。" : "来源扫描只读，托管副本可独立使用。")
                                .font(.caption).foregroundStyle(.secondary)
                            if model.archivingID == file.id {
                                HStack { ProgressView().controlSize(.small); Text("正在复制并校验…") }.font(.caption)
                            }
                        }
                        DisclosureGroup("文件信息") {
                            VStack(alignment: .leading, spacing: 12) {
                                property("来源", value: file.sourceName)
                                property("修改日期", value: file.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")
                                property("创建日期", value: file.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")
                                if let date = file.managedAt { property("副本保存日期", value: date.formatted(date: .abbreviated, time: .shortened)) }
                                property(file.isImported ? "收纳时原路径（仅供参考）" : "原始路径", value: file.fullPath)
                            }.padding(.top, 8)
                        }
                        if file.textNeedsRefresh {
                            Label("正文需要更新，旧内容不参与搜索。", systemImage: "arrow.clockwise")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("隐私与全文搜索") {
                            VStack(alignment: .leading, spacing: 16) {
                                SensitivityControl(file: file)
                                Divider()
                                documentSearch(file)
                            }.padding(.top, 8)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
            } else {
                ContentUnavailableView("选择一份资料", systemImage: "doc.text.magnifyingglass",
                    description: Text("查看文件预览、关联对象和详细信息。"))
            }
        }
        .task(id: model.selectedFile) {
            model.preparePreview()
            await model.reloadLinkedObjects()
        }
    }

    private func fileActions(_ file: LibraryFile) -> some View {
        HStack {
            Button(model.previewIsManaged ? "打开托管副本" : "打开原件", systemImage: "arrow.up.right.square") {
                if model.previewIsManaged { model.openManagedCopy() } else { model.openOriginal() }
            }
                .disabled(model.previewURL == nil)
            Button("系统预览", systemImage: "eye") { model.quickLook(preferManaged: model.previewIsManaged) }
                .disabled(model.previewURL == nil).help("放大预览（空格）")
            Spacer(minLength: 0)
            Menu {
                Button(file.isImported ? "在 Finder 中显示副本" : "在 Finder 中显示原件") { model.revealSelected() }
                    .disabled(file.isImported ? model.managedURL == nil : model.originalURL == nil)
                if !file.isImported, file.managedCopyPath != nil {
                    Button("打开托管副本") { model.openManagedCopy() }.disabled(model.managedURL == nil)
                    Button("预览托管副本") { model.quickLook(preferManaged: true) }.disabled(model.managedURL == nil)
                } else if file.managedCopyPath == nil {
                    Button("保存副本到资料库") { Task { await model.archiveSelected() } }
                        .disabled(model.originalURL == nil || model.archivingID != nil)
                }
                if model.currentObjectID != nil {
                    Button("在所有资料中查看") { Task { await model.showInLibrary(file) } }
                }
                if file.isImported {
                    Divider()
                    Button("从 PersonalSpace 移除…", role: .destructive) { model.requestImportedRemoval(file) }
                        .disabled(model.removingFileID != nil || model.pendingCopyRemoval != nil)
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("文件操作")
        }.controlSize(.small)
    }

    @ViewBuilder private var preview: some View {
        if let url = model.previewURL {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.previewIsManaged ? "预览托管副本" : "预览原文件").font(.caption).foregroundStyle(.secondary)
                SystemPreview(url: url).frame(height: 200)
                    .accessibilityLabel(model.previewIsManaged ? "托管副本系统预览" : "原文件系统预览")
            }
        } else {
            ContentUnavailableView {
                Label("文件暂不可用", systemImage: "doc.badge.exclamationmark")
            } description: { Text(model.previewError ?? "请刷新或重新授权来源。") }.frame(minHeight: 150)
        }
    }

    @ViewBuilder private func documentSearch(_ file: LibraryFile) -> some View {
        Text("全文搜索").font(.headline)
        if let date = file.textIndexedAt {
            Label("此正文已加入搜索", systemImage: "text.badge.checkmark").font(.callout).foregroundStyle(.secondary)
            Text("更新于 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Button("重新识别并保存正文") { Task { await model.indexSelectedDocument() } }
                .disabled(!canIndex(file))
            Button("移除正文索引") { Task { await model.removeDocumentText(file) } }
            if !file.isImported, !file.isAvailable || file.sourceError != nil {
                Text("原件不可用期间，此正文不参与全文搜索。").font(.caption).foregroundStyle(.secondary)
            }
        } else if file.sensitivity != "normal" {
            Text("敏感或疑似敏感资料不读取正文、不保存正文索引、不交给模型。")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            if file.textNeedsRefresh {
                Label("文件已变化，旧正文已移除。请重新识别。", systemImage: "arrow.clockwise")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("仅在你确认后识别，正文以明文保存在本机供全文搜索。")
                .font(.callout).foregroundStyle(.secondary)
            if model.indexingID == file.id {
                HStack { ProgressView().controlSize(.small); Text("正在识别并保存正文…") }
            } else {
                Button(file.textNeedsRefresh ? "重新识别并保存正文" : "识别并保存正文以供搜索") { Task { await model.indexSelectedDocument() } }
                    .disabled(!canIndex(file))
            }
        }
    }

    private func canIndex(_ file: LibraryFile) -> Bool {
        model.indexingID == nil && model.previewURL != nil
            && (file.isImported || (file.isAvailable && file.sourceError == nil))
    }

    private func property(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SensitivityControl: View {
    @EnvironmentObject private var model: LibraryModel
    let file: LibraryFile
    @State private var updating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("隐私标记").font(.headline)
            Picker("资料标记", selection: Binding(get: { file.sensitivity }, set: { value in
                updating = true
                Task { await model.setSensitivity(file, state: value); updating = false }
            })) {
                Text("普通").tag("normal")
                Text("疑似敏感").tag("suspected")
                Text("敏感").tag("sensitive")
            }.disabled(updating)
            Text("标为敏感会移除已保存的正文索引；名称与路径仍可搜索。改回普通后，需要主动重新建立正文索引。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct QuickLookSheet: View {
    @EnvironmentObject var model: LibraryModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((model.selectedFile?.name ?? "系统预览") + (model.previewIsManaged ? " · 托管副本" : "")).font(.headline).lineLimit(1)
                Spacer()
                Button("完成") { model.showQuickLook = false }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            if let url = model.previewURL { SystemPreview(url: url).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 560, minHeight: 500)
    }
}
