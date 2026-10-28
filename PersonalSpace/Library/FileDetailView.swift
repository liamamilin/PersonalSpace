import SwiftUI
import Quartz

struct SystemPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
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
            if let file = model.selectedFile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.name).font(.headline).textSelection(.enabled)
                            Text("\(file.kind) · \(file.size)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let url = model.previewURL {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(model.previewIsManaged ? "正在预览托管副本" : "正在预览原文件")
                                    .font(.caption).foregroundStyle(.secondary)
                                SystemPreview(url: url).frame(height: 250)
                                    .accessibilityLabel(model.previewIsManaged ? "托管副本系统预览" : "原文件系统预览")
                            }
                        } else {
                            ContentUnavailableView {
                                Label("文件暂不可用", systemImage: "doc.badge.exclamationmark")
                            } description: {
                                Text(model.previewError ?? "请刷新或重新授权来源。")
                            }.frame(minHeight: 170)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("原文件").font(.headline)
                            if let error = model.originalError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("打开原件", systemImage: "arrow.up.right.square") { model.openOriginal() }
                                Button("在 Finder 中显示", systemImage: "folder") { model.revealSelected() }
                            }.controlSize(.small).disabled(model.originalURL == nil)
                            if model.originalURL == nil,
                               let source = model.sources.first(where: { $0.id == file.sourceID }) {
                                HStack {
                                    Button("刷新来源") { model.refresh(source) }
                                    Button("重新授权") { model.addFolders(replacing: source) }
                                }.controlSize(.small).disabled(model.scanning[source.id] != nil)
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("托管副本").font(.headline)
                            if file.managedCopyPath != nil {
                                if let error = model.managedError {
                                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                } else {
                                    Label("已保存到本地资料库并完成校验", systemImage: "checkmark.circle")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("打开托管副本") { model.openManagedCopy() }
                                    Button("预览副本", systemImage: "eye") { model.quickLook(preferManaged: true) }
                                }.controlSize(.small).disabled(model.managedURL == nil)
                                if let date = file.managedAt {
                                    Text("保存于 " + date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("主动复制一份凭证；原文件不会移动或修改。")
                                    .font(.callout).foregroundStyle(.secondary)
                                if model.archivingID == file.id {
                                    HStack { ProgressView().controlSize(.small); Text("正在复制并校验…") }
                                } else {
                                    Button("保存副本到资料库", systemImage: "externaldrive.badge.plus") {
                                        Task { await model.archiveSelected() }
                                    }.disabled(model.originalURL == nil || model.archivingID != nil)
                                }
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("关联的对象").font(.headline)
                                Spacer()
                                Button("关联", systemImage: "link") { model.showLinkSheet = true }
                            }
                            if model.linkedObjects.isEmpty {
                                Text("尚未关联个人对象").font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(model.linkedObjects) { object in
                                HStack {
                                    Button(object.name) { model.showObject(object.id) }.buttonStyle(.link)
                                    Spacer()
                                    Button("解除关联", systemImage: "xmark") {
                                        Task { await model.unlink(file.id, from: object.id) }
                                    }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                        .help("解除与「\(object.name)」的关联，保留原文件")
                                }
                            }
                            if model.currentObjectID != nil {
                                Button("在资料库中查看") { Task { await model.showInLibrary(file) } }
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("订单跟进").font(.headline)
                            Button("从此凭证创建订单", systemImage: "doc.badge.plus") { model.createOrder() }
                            Text("可按需识别文字、校对事实，再填写明确的提醒日期。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 14) {
                            Text("文件信息").font(.headline)
                            property("来源", value: file.sourceName)
                            property("大小", value: file.size)
                            property("修改日期", value: file.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")
                            property("创建日期", value: file.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")
                            property("原始路径", value: file.fullPath)
                        }
                    }.padding(20)
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

    private func property(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
