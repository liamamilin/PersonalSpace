import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var removing: FolderSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("已授权来源").font(.title2.bold())
                    Text("文件保留在原位置，仅在这台 Mac 上建立索引。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加文件夹", systemImage: "folder.badge.plus") { model.addFolders() }
                    .disabled(model.storageUnavailable)
            }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if model.sources.isEmpty {
                ContentUnavailableView("尚未添加来源", systemImage: "folder",
                    description: Text("选择你希望在资料库中查找的文件夹。"))
            } else {
                List(model.sources) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(source.name, systemImage: "folder").font(.headline)
                            Spacer()
                            if let count = model.scanning[source.id] {
                                ProgressView().controlSize(.small)
                                Text("已发现 \(count) 个文件").font(.caption).foregroundStyle(.secondary)
                            } else { Text("\(source.fileCount) 个文件").foregroundStyle(.secondary) }
                        }
                        Text(source.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if let error = source.lastError {
                            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        } else {
                            Text(source.lastScannedAt.map { "上次扫描：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未完成扫描")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if model.scanning[source.id] != nil {
                                Button("停止扫描") { model.cancelScan(source) }
                            } else {
                                Button("刷新") { model.refresh(source) }
                            }
                            Button("重新授权") { model.addFolders(replacing: source) }
                                .disabled(model.scanning[source.id] != nil)
                            Spacer()
                            Button("移除来源", role: .destructive) { removing = source }
                        }.controlSize(.small)
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
            Text("移除来源停止访问该文件夹，保留已有对象关联与托管副本；原文件不变。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 640, height: 440)
        .alert("移除来源？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("移除来源", role: .destructive) {
                if let source = removing { Task { await model.remove(source) } }
                removing = nil
            }
        } message: { Text("此来源将从普通资料库中隐藏。已关联资料与托管副本保留，原文件保持不变。") }
    }
}
