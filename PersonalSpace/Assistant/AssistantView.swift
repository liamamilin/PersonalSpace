import SwiftUI

struct AssistantView: View {
    @EnvironmentObject private var assistant: AssistantController
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var inputFocused: Bool

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
                            }.id("working")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                .onChange(of: assistant.lines.count) {
                    if let id = assistant.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
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

    @ViewBuilder private func lineView(_ line: AssistantLine) -> some View {
        switch line.kind {
        case .operation:
            Label(line.text, systemImage: "arrow.turn.down.right")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        case .error:
            Label(line.text, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
        case .user, .assistant:
            VStack(alignment: .leading, spacing: 6) {
                Text(line.kind == .user ? "你" : "助手").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
