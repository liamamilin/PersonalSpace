import SwiftUI

/// Calm, native macOS overview showing only real pending actions, inbox items,
/// recent matters/objects, and source health—never decorative charts or zero KPIs.
struct OverviewView: View {
    @EnvironmentObject private var model: LibraryModel

    private var activeActions: [ActionRecord] {
        model.actions
            .filter { $0.state == "active" }
            .sorted { ($0.remindAt ?? .distantFuture) < ($1.remindAt ?? .distantFuture) }
    }

    private var needsDateActions: [ActionRecord] {
        model.actions.filter { $0.state == "needs_date" }
    }

    private var recentMatters: [MatterRecord] {
        Array(model.matters.prefix(5))
    }

    private var recentObjects: [PersonalObject] {
        Array(model.objects.sorted { $0.updatedAt > $1.updatedAt }.prefix(6))
    }

    private var sourcesNeedingAttention: [FolderSource] {
        model.sources.filter {
            $0.needsAuthorization || $0.lastError != nil || !($0.scanReport?.unreadable.isEmpty ?? true)
        }
    }

    private var isCompletelyEmpty: Bool {
        model.sources.isEmpty && model.total == 0 && model.inboxCount == 0
            && model.objects.isEmpty && model.matters.isEmpty && model.actions.isEmpty
    }

    var body: some View {
        if isCompletelyEmpty {
            FirstRunWelcomeView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !activeActions.isEmpty || !needsDateActions.isEmpty {
                        actionsSection
                    }
                    if model.inboxCount > 0 || !sourcesNeedingAttention.isEmpty {
                        attentionSection
                    }
                    if !recentMatters.isEmpty {
                        mattersSection
                    }
                    if !recentObjects.isEmpty {
                        objectsSection
                    }
                    if !model.sources.isEmpty {
                        sourcesSection
                    }
                    if activeActions.isEmpty && needsDateActions.isEmpty && model.inboxCount == 0
                        && sourcesNeedingAttention.isEmpty && recentMatters.isEmpty
                        && recentObjects.isEmpty && !model.sources.isEmpty {
                        quietLibraryHint
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("即将到期与待处理").font(.headline)
                Spacer()
                Button("查看全部待办") { model.selectedSourceID = "actions" }
                    .buttonStyle(.link)
            }
            if !activeActions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(activeActions.prefix(5))) { action in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: model.pendingActionIDs.contains(action.id) ? "bell.badge" : "circle")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Button {
                                    if let matterID = action.matterID {
                                        Task { await model.showMatter(matterID, actionID: action.id) }
                                    } else {
                                        model.selectedActionID = action.id
                                        model.selectedSourceID = "actions"
                                    }
                                } label: {
                                    Text(action.title).lineLimit(1)
                                }.buttonStyle(.link)
                                HStack(spacing: 8) {
                                    if let matterTitle = action.matterTitle {
                                        Text(matterTitle).lineLimit(1)
                                    }
                                    if let remindAt = action.remindAt {
                                        Text("· " + remindAt.formatted(date: .abbreviated, time: .shortened))
                                    }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("完成", systemImage: "checkmark") {
                                Task { await model.setActionState(action, state: "done") }
                            }.controlSize(.small)
                        }
                    }
                }
            }
            if !needsDateActions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
                    Text("另有 \(needsDateActions.count) 项待补日期的行动").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("去确认日期") { model.selectedSourceID = "actions" }
                        .buttonStyle(.link)
                }.padding(.top, activeActions.isEmpty ? 0 : 4)
            }
            Divider().padding(.top, 4)
        }
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("待整理与来源提醒").font(.headline)
            if model.inboxCount > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary).frame(width: 18)
                    Text("待整理中有 \(model.inboxCount.formatted()) 份已收纳文件，尚未关联个人对象或事务。")
                        .font(.callout)
                    Spacer()
                    Button("前往待整理") { model.selectedSourceID = "inbox" }
                        .buttonStyle(.link)
                }
            }
            ForEach(sourcesNeedingAttention) { source in
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name).font(.callout.weight(.medium))
                        Text(sourceAttentionReason(source)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if source.needsAuthorization {
                        Button("重新授权") { model.addFolders(replacing: source) }
                            .controlSize(.small)
                            .disabled(model.scanning[source.id] != nil)
                    } else {
                        Button("查看来源") { model.selectedSourceID = source.id }
                            .buttonStyle(.link)
                    }
                }
            }
            Divider().padding(.top, 4)
        }
    }

    private var mattersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近更新的事务").font(.headline)
                Spacer()
                Button("全部事务") { model.selectedSourceID = "matters" }
                    .buttonStyle(.link)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(recentMatters) { matter in
                    let kind = MatterKind(rawValue: matter.kind) ?? .order
                    let next = model.actions.first { $0.matterID == matter.id && ["active", "needs_date"].contains($0.state) }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: kind.image).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                Task { await model.showMatter(matter.id) }
                            } label: {
                                Text(matter.title).lineLimit(1)
                            }.buttonStyle(.link)
                            Text(next.map { "下一步：\($0.title)" } ?? (matter.status == "completed" ? "已完成" : "\(kind.title) · \(matter.itemCount) 份凭证"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(matter.updatedAt.formatted(date: .numeric, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider().padding(.top, 4)
        }
    }

    private var objectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("个人对象").font(.headline)
                Spacer()
                Button("全部对象") { model.selectedSourceID = "objects" }
                    .buttonStyle(.link)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(recentObjects) { object in
                    HStack(spacing: 12) {
                        Image(systemName: object.kind == "device" ? "desktopcomputer" : "square.stack.3d.up")
                            .foregroundStyle(.secondary).frame(width: 18)
                        Button { model.showObject(object.id) } label: {
                            Text(object.name).lineLimit(1)
                        }.buttonStyle(.link)
                        Spacer()
                        Text("\(object.itemCount.formatted()) 份资料")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider().padding(.top, 4)
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已授权文件夹").font(.headline)
                Spacer()
                Button("添加文件夹…") { model.addFolders() }
                    .buttonStyle(.link)
                    .disabled(model.storageUnavailable)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.sources) { source in
                    HStack(spacing: 12) {
                        Image(systemName: source.lastError == nil ? "folder" : "folder.badge.questionmark")
                            .foregroundStyle(.secondary).frame(width: 18)
                        Button { model.selectedSourceID = source.id } label: {
                            Text(source.name).lineLimit(1)
                        }.buttonStyle(.link)
                        Spacer()
                        if let count = model.scanning[source.id] {
                            Text("扫描中 · \(count.formatted())").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(source.fileCount.formatted()) 份资料" + (source.autoUpdatePaused ? " · 自动更新已暂停" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var quietLibraryHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("下一步建议").font(.headline)
            Text("已建立文件夹索引。可以按 ⌘F 搜索资料，创建个人对象归拢相关凭证，或从发票与合同建立事务与提醒。")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("创建个人对象…") { model.createObject() }
                Button("创建事务…") { model.createMatter(kind: .order) }
            }.padding(.top, 2)
        }
    }

    private func sourceAttentionReason(_ source: FolderSource) -> String {
        if source.needsAuthorization { return "需要重新授权后才能访问原件与自动更新。" }
        if let error = source.lastError { return error }
        let count = source.scanReport?.unreadable.count ?? 0
        return "\(count) 个位置未能读取，其他资料已正常登记。"
    }
}
