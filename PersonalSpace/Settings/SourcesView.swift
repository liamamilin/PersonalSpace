import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var removing: FolderSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("已授权来源").font(.title2.bold())
                    Text("应用运行时自动更新已授权文件夹；原文件保留在原位置。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加文件夹", systemImage: "folder.badge.plus") { model.addFolders() }
                    .disabled(model.storageUnavailable)
            }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            FolderCountingBanner()
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
                                Text(model.updatingSourceIDs.contains(source.id) ? "更新中 · 已处理 \(count) 个文件" : "已发现 \(count) 个文件")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else { Text("\(source.fileCount) 条资料记录").foregroundStyle(.secondary) }
                        }
                        Text(source.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if source.needsAuthorization {
                            Label("需要重新授权", systemImage: "lock.trianglebadge.exclamationmark")
                                .font(.callout).foregroundStyle(.orange)
                            Text("选择对应文件夹即可恢复访问，新电脑上的路径可以不同；已有资料关联保留。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !source.needsAuthorization, let error = source.lastError {
                            Label("上次扫描：" + error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        } else if let report = source.scanReport {
                            Text("上次遍历结束：" + report.completedAt.formatted(date: .abbreviated, time: .shortened)
                                 + " · 登记 \(report.fileCount) 个文件")
                                .font(.caption).foregroundStyle(.secondary)
                            if !report.unreadable.isEmpty {
                                DisclosureGroup("\(report.unreadable.count) 个位置未能读取，其他资料已登记") {
                                    ForEach(report.unreadable) { issue in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(issue.path).textSelection(.enabled)
                                            Text(issue.reason).foregroundStyle(.secondary)
                                        }.font(.caption).padding(.vertical, 3)
                                    }
                                }.font(.callout).foregroundStyle(.orange)
                            }
                        } else if !source.needsAuthorization {
                            Text(source.lastScannedAt.map { "上次扫描：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未完成扫描")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if source.autoUpdatePaused {
                            Label("自动更新已暂停；手动刷新只扫描一次。", systemImage: "pause.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !source.needsAuthorization, source.lastError == nil, let error = model.monitoringErrors[source.id] {
                            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        } else if !source.needsAuthorization, model.monitoredSourceIDs.contains(source.id) {
                            Label("自动更新已开启", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if model.scanning[source.id] != nil {
                                Button("停止扫描") { model.cancelScan(source) }
                                    .help("停止本次扫描并暂停自动更新，重开应用后仍保持暂停。")
                            } else {
                                Button("刷新") { model.refresh(source) }.disabled(source.needsAuthorization)
                                if source.autoUpdatePaused {
                                    Button("恢复自动更新") { Task { await model.resumeAutomaticUpdates(source) } }
                                        .disabled(source.needsAuthorization)
                                } else {
                                    Button("暂停自动更新") { model.cancelScan(source) }
                                }
                            }
                            Button("重新授权") { model.addFolders(replacing: source) }
                                .disabled(model.scanning[source.id] != nil)
                            Spacer()
                            Button("移除来源", role: .destructive) { removing = source }
                        }.controlSize(.small)
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
            Text("建议添加存放资料的具体文件夹。移除来源保留已有对象关联与托管副本，原文件不变。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 640, height: 440)
        .modifier(SourceRemovalConfirmation(source: $removing))
    }
}

struct FolderCountingBanner: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        if let name = model.countingFolderName {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在统计「\(name)」· 已计数 \(model.countedFiles.formatted()) 个文件")
                    Text("仅统计可读取的文件，不读取正文、不建立索引。大文件夹需要等待。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消统计") { model.cancelFolderCount() }
            }
            .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5))
        }
    }
}

struct SourceRemovalConfirmation: ViewModifier {
    @EnvironmentObject private var model: LibraryModel
    @Binding var source: FolderSource?

    func body(content: Content) -> some View {
        content.alert("移除来源“\(source?.name ?? "")”？", isPresented: Binding(
            get: { source != nil }, set: { if !$0 { source = nil } }
        ), presenting: source) { pendingSource in
            Button("取消", role: .cancel) { source = nil }
            Button("移除来源", role: .destructive) {
                Task { await model.remove(pendingSource) }
                source = nil
            }
        } message: { _ in
            Text("将停止此来源的扫描和自动更新，并从普通资料库中隐藏。已有关联与托管副本保留，不会删除或修改原文件。重新添加此文件夹可恢复访问。")
        }
    }
}
