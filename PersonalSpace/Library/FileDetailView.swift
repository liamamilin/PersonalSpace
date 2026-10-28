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
                            SystemPreview(url: url).frame(height: 260)
                                .accessibilityLabel("原文件系统预览")
                        } else {
                            ContentUnavailableView {
                                Label("原位置已不可用", systemImage: "doc.badge.exclamationmark")
                            } description: {
                                Text(model.previewError ?? file.sourceError ?? "请刷新或重新授权来源。")
                            } actions: {
                                if let source = model.sources.first(where: { $0.id == file.sourceID }) {
                                    Button("刷新来源") { model.refresh(source) }.disabled(model.scanning[source.id] != nil)
                                    Button("重新授权") { model.addFolders(replacing: source) }
                                        .disabled(model.scanning[source.id] != nil)
                                }
                            }
                            .frame(minHeight: 200)
                        }
                        HStack {
                            Button("打开原件", systemImage: "arrow.up.right.square") { model.openSelected() }
                            Button("在 Finder 中显示", systemImage: "folder") { model.revealSelected() }
                        }
                        .controlSize(.small)
                        .disabled(model.previewURL == nil)
                        Button("系统预览", systemImage: "eye") { model.quickLook() }
                            .disabled(model.previewURL == nil)
                            .help("预览所选原文件（空格键）")
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
                    description: Text("查看原文件预览、位置和详细信息。"))
            }
        }
        .task(id: model.selectedFile) { model.preparePreview() }
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
                Text(model.selectedFile?.name ?? "系统预览").font(.headline).lineLimit(1)
                Spacer()
                Button("完成") { model.showQuickLook = false }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            if let url = model.previewURL { SystemPreview(url: url).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 560, minHeight: 500)
    }
}
