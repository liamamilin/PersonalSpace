import SwiftUI

struct AssistantView: View {
    @EnvironmentObject private var assistant: AssistantController
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var inputFocused: Bool
    @State private var followOutput = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PersonalSpace 助手").font(.headline)
                    Text("查找、收纳、整理和跟进，用一句话开始。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("新对话", systemImage: "square.and.pencil") { assistant.clear(); inputFocused = true }
                    .labelStyle(.iconOnly).disabled(assistant.busy)
            }.padding(16)
            Divider()
            HStack {
                if !assistant.models.isEmpty {
                    Picker("本机模型", selection: $assistant.selectedModel) {
                        ForEach(assistant.models) { Text($0.name).tag($0.name) }
                    }.labelsHidden().frame(maxWidth: 320).disabled(assistant.busy)
                } else { Text("本机 Ollama").font(.callout) }
                Spacer()
                if assistant.connecting { ProgressView().controlSize(.small) }
                Button("重新连接", systemImage: "arrow.clockwise") { Task { await assistant.connect() } }
                    .labelStyle(.iconOnly).disabled(assistant.connecting || assistant.busy)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            if let error = assistant.connectionError {
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if assistant.lines.isEmpty { welcome }
                        ForEach(assistant.lines) { line in
                            lineView(line).id(line.id)
                        }
                        if assistant.busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(assistant.status).font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                elapsed(since: assistant.startedAt, until: nil)
                            }
                            if assistant.canRevealPanel {
                                Button("显示操作窗口", systemImage: "macwindow") { assistant.showOperationWindow() }
                                    .controlSize(.small)
                            }
                        } else if assistant.awaitingConfirmation {
                            Button("返回确认或编辑窗口", systemImage: "macwindow") { assistant.showOperationWindow() }
                                .controlSize(.small)
                        }
                        Color.clear.frame(height: 1).id("conversation-end")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
                } action: { _, nearBottom in followOutput = nearBottom }
                .onChange(of: assistant.lines.count) {
                    if followOutput { proxy.scrollTo("conversation-end", anchor: .bottom) }
                }
                .onChange(of: assistant.lines.last?.text) {
                    if followOutput { proxy.scrollTo("conversation-end", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followOutput && !assistant.lines.isEmpty {
                        Button("回到底部", systemImage: "arrow.down") {
                            followOutput = true; proxy.scrollTo("conversation-end", anchor: .bottom)
                        }.controlSize(.small).padding(12)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $assistant.input)
                    .font(.body).frame(minHeight: 60, maxHeight: 100)
                    .focused($inputFocused).accessibilityLabel("告诉助手你想做什么")
                    .accessibilityIdentifier("assistant-input")
                    .overlay(alignment: .topLeading) {
                        if assistant.input.isEmpty {
                            Text("例如：帮我扫描一个文件夹，找出值得整理的资料")
                                .foregroundStyle(.tertiary).padding(.top, 5).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Text(assistant.busy ? assistant.status : "本机处理 · 对话仅保留在本次会话")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if assistant.busy { elapsed(since: assistant.startedAt, until: nil) }
                    if assistant.busy {
                        Button("停止") { assistant.stop() }.accessibilityIdentifier("assistant-stop")
                    } else {
                        Button("发送", systemImage: "arrow.up") { assistant.send() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(assistant.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.connecting)
                            .accessibilityIdentifier("assistant-send")
                    }
                }
            }.padding(16)
        }
        .frame(minWidth: 480, minHeight: 540)
        .task { assistant.openSettings = { openSettings() }; await assistant.connect(); inputFocused = true }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("你想先处理什么？").font(.title2.weight(.semibold))
            Text("我可以使用资料库里的现有功能。新位置会请你选择授权，事务和提醒建议会打开编辑器让你核对。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(["帮我扫描一个文件夹，找出值得整理的资料", "查找我的电脑相关资料和待办", "创建一个名为「我的电脑」的个人对象", "帮我导出当前资料库备份"], id: \.self) { prompt in
                Button(prompt) { assistant.input = prompt; inputFocused = true }
                    .buttonStyle(.link)
            }
            Text("文件、正文和模型回复中的建议，需要结合实际操作结果判断。原文件始终保留在原位置。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 14)
    }

    @ViewBuilder private func elapsed(since start: Date?, until end: Date?) -> some View {
        if let start {
            if let end { duration(max(0, Int(end.timeIntervalSince(start)))) }
            else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    duration(max(0, Int(context.date.timeIntervalSince(start))))
                }
            }
        }
    }

    private func duration(_ seconds: Int) -> some View {
        Text(seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分 \(seconds % 60) 秒")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            .accessibilityLabel("已用时 \(seconds) 秒")
    }

    @ViewBuilder private func lineView(_ line: AssistantLine) -> some View {
        switch line.kind {
        case .operation:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    if line.operationState == .running && assistant.waitingForPanel { Image(systemName: "hand.raised") }
                    else if line.operationState == .running { ProgressView().controlSize(.mini) }
                    else { Image(systemName: line.operationState == .failed ? "exclamationmark.triangle" : line.operationState == .waiting ? "hand.raised" : "arrow.turn.down.right") }
                    Text(line.text).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Text(line.operationState == .running && assistant.waitingForPanel ? "待你操作" : line.operationState?.rawValue ?? "已结束").font(.caption)
                    elapsed(since: line.startedAt, until: line.finishedAt)
                }
                if let detail = line.detail { Text(detail).font(.caption).textSelection(.enabled) }
                if line.operationState == .running {
                    if line.toolName == "source_operation" {
                        ForEach(library.scanning.keys.sorted().filter { line.sourceID == nil || line.sourceID == $0 }, id: \.self) { id in
                            let name = library.sources.first(where: { $0.id == id })?.name ?? "文件夹"
                            Text("「\(name)」已扫描 \(library.scanning[id] ?? 0) 份文件")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    if ["file_operation", "choose_files_and_import"].contains(line.toolName ?? ""), library.isImporting {
                        Text("当前复制：\(library.importCompleted) / \(library.importingTotal)")
                            .font(.caption.monospacedDigit())
                    }
                }
            }.font(.callout)
                .foregroundStyle(line.operationState == .failed ? Color.orange : Color.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
        case .error:
            Label(line.text, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
        case .user, .assistant:
            VStack(alignment: .leading, spacing: 6) {
                Text(line.kind == .user ? "你" : "助手").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(LocalizedStringKey(line.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if line.isPartial {
                    Text(assistant.busy ? "正在输出…" : "此段回复未完成").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
