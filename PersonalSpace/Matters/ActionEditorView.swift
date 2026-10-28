import SwiftUI

struct ActionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ActionDraft
    @State private var dueDate: Date
    @State private var reminderDate: Date
    @State private var hasDueDate: Bool
    @State private var saving = false
    @State private var message: String?
    private let original: ActionDraft
    let saveAction: @MainActor (ActionDraft) async -> Bool

    init(draft: ActionDraft, saveAction: @escaping @MainActor (ActionDraft) async -> Bool) {
        self.original = draft
        self.saveAction = saveAction
        _draft = State(initialValue: draft)
        _dueDate = State(initialValue: draft.dueDate ?? Date())
        _reminderDate = State(initialValue: draft.remindAt ?? Date().addingTimeInterval(3_600))
        _hasDueDate = State(initialValue: draft.dueDate != nil)
    }

    private var terminal: Bool { ["done", "cancelled"].contains(draft.state) }
    private var invalidReminder: Bool {
        !terminal && draft.dateConfirmed && reminderDate <= Date()
            && (original.remindAt != reminderDate || !original.dateConfirmed || original.state != "active")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("编辑行动").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider()
            Form {
                TextField("标题", text: $draft.title).accessibilityIdentifier("action-title")
                Picker("状态", selection: $draft.state) {
                    Text("待处理 / 待补日期").tag(terminal ? "needs_date" : draft.state)
                    Text("已完成").tag("done")
                    Text("已取消").tag("cancelled")
                }
                Toggle("设置行动日期", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("行动日期", selection: $dueDate, displayedComponents: [.date])
                }
                Toggle("我已确认具体提醒日期和时间", isOn: $draft.dateConfirmed)
                    .accessibilityIdentifier("action-date-confirmed")
                if draft.dateConfirmed {
                    DatePicker("提醒时间", selection: $reminderDate, displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("action-reminder-date")
                } else if !terminal {
                    Text("保存为「待补日期」，不会安排系统通知。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if invalidReminder {
                    Text("请选择未来的具体提醒时间。")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text("每条行动独立保存日期、状态和系统提醒。未知日期可留空；完成或取消仅撤销此行动的通知。")
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            Divider()
            HStack {
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "正在保存…" : "保存行动") {
                    var edited = draft
                    edited.dueDate = hasDueDate ? dueDate : nil
                    edited.remindAt = draft.dateConfirmed ? reminderDate : nil
                    if !terminal { edited.state = draft.dateConfirmed ? "active" : "needs_date" }
                    saving = true
                    Task {
                        if await saveAction(edited) { dismiss() }
                        else { message = "行动未保存，请检查提示后重试。" }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(saving || invalidReminder || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(20)
        }.frame(width: 550, height: 480)
            .interactiveDismissDisabled(saving)
    }
}

struct ActionTimingView: View {
    @EnvironmentObject private var model: LibraryModel
    let action: ActionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let due = action.dueDate {
                Text("行动日期：" + due.formatted(date: .abbreviated, time: .omitted))
            }
            if let reminder = action.remindAt, action.dateConfirmed {
                Text("提醒时间：" + reminder.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("尚未确认具体提醒时间")
            }
            if let actual = model.pendingReminderDates[action.id] {
                Label("系统待发送：" + actual.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.badge")
            } else {
                Label(model.deliveredActionIDs.contains(action.id) ? "已送达通知中心" : "当前没有待发送通知",
                      systemImage: model.deliveredActionIDs.contains(action.id) ? "bell" : "bell.slash")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}
