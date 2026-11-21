import Foundation

extension LibraryModel {
    func createOrder() {
        createMatter(kind: .order)
    }

    @discardableResult
    func createMatter(kind: MatterKind) -> Task<Void, Never> {
        errorMessage = nil
        // Capture this operation's context before the database query can suspend.
        let itemID = isFileList ? selectedFile?.id : nil
        let objectID = currentObjectID
        var draft = MatterDraft()
        draft.kind = kind.rawValue
        draft.itemIDs = itemID.map { [$0] } ?? []
        draft.objectID = objectID
        matterDraft = draft
        matterObjectSelectionMessage = nil
        return Task {
            do {
                var message: String?
                if objectID == nil, let itemID, let database {
                    let owners = try await database.objectsForItem(itemID)
                    if owners.count == 1 { draft.objectID = owners[0].id }
                    else if owners.count > 1 {
                        message = "此凭证关联了多个个人对象，请选择本事务的关联对象，也可保持不关联。"
                    }
                }
                guard matterDraft.id == draft.id else { return }
                matterDraft = draft
                matterObjectSelectionMessage = message
                showMatterEditor = true
            } catch {
                guard matterDraft.id == draft.id else { return }
                errorMessage = "读取凭证的对象关联失败，请重试。"
            }
        }
    }

    func editMatter(_ matter: MatterRecord) async {
        guard let database else { return }
        do {
            let facts = try await database.facts(matterID: matter.id)
            let files = try await database.files(FileQuery(matterID: matter.id, limit: Int.max)).files
            let actions = try await database.actions(matterID: matter.id)
            var draft = MatterDraft(id: matter.id, kind: matter.kind, title: matter.title,
                status: matter.status, objectID: matter.objectID, notes: matter.notes,
                itemIDs: files.map(\.id))
            draft.facts = facts.map {
                FactDraft(id: $0.id, key: $0.key, valueText: $0.valueText, valueType: $0.valueType,
                    state: $0.state, sourceItemID: $0.sourceItemID,
                    sourceExcerpt: $0.sourceExcerpt, origin: $0.origin)
            }
            draft.actions = actions.map(ActionDraft.init)
            matterDraft = draft
            matterObjectSelectionMessage = nil
            showMatterEditor = true
        } catch { errorMessage = "无法读取事务，请重试。" }
    }

    func showMatter(_ id: String, actionID: String? = nil) async {
        selectedActionID = actionID
        search = ""
        selectedFileID = nil
        selectedSourceID = "matters"
        selectedMatterID = id
        await loadMatterDetails()
    }

    func openAction(_ id: String) async {
        guard let database else { return }
        do {
            guard let action = try await database.action(id: id) else {
                errorMessage = "此提醒对应的行动已不存在。"
                return
            }
            selectedActionID = id
            if let matterID = action.matterID { await showMatter(matterID, actionID: id) }
            else { selectedSourceID = "actions"; await reload() }
        } catch { errorMessage = "无法打开提醒对应的行动，请在待办中查看。" }
    }

    func loadMatterDetails() async {
        guard let database, let id = selectedMatterID else {
            matterFacts = []; matterFiles = []
            return
        }
        do {
            let facts = try await database.facts(matterID: id)
            let files = try await database.files(FileQuery(matterID: id, limit: Int.max)).files
            guard selectedMatterID == id, !Task.isCancelled else { return }
            matterFacts = facts
            matterFiles = files
        } catch {
            guard selectedMatterID == id, !Task.isCancelled else { return }
            errorMessage = "读取事务详情失败，请重试。"
        }
    }

    func saveMatter(_ draft: MatterDraft) async -> Bool {
        guard let database else { return false }
        do {
            let previous = try await database.actions(matterID: draft.id)
            for action in draft.actions {
                try validateReminder(action, previous: previous.first { $0.id == action.id })
            }
            let saved = try await database.saveMatter(draft)
            for action in saved {
                await updateReminder(action, previous: previous.first { $0.id == action.id })
            }
            if saved.isEmpty { reminderMessage = "事务已保存，已有行动与提醒保持不变。" }
            await reload()
            await showMatter(draft.id)
            await refreshReminderStatus(updateMessage: false)
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "保存事务失败，请检查字段后重试。"
            return false
        }
    }

    private func validateReminder(_ draft: ActionDraft, previous: ActionRecord?) throws {
        guard !["done", "cancelled"].contains(draft.state), draft.dateConfirmed else { return }
        let changed = previous?.remindAt != draft.remindAt || previous?.dateConfirmed != true
            || previous?.state != "active"
        if changed, draft.remindAt.map({ $0 > Date() }) != true {
            throw ReminderEditError.futureTimeRequired
        }
    }

    private func updateReminder(_ saved: ActionRecord, previous: ActionRecord?) async {
        guard previous == nil || previous?.remindAt != saved.remindAt
                || previous?.dateConfirmed != saved.dateConfirmed || previous?.state != saved.state else {
            reminderMessage = "行动已保存，原提醒保持不变。"
            return
        }
        reminderMessage = await reminders.apply(actionID: saved.id, title: saved.title,
            remindAt: saved.remindAt, dateConfirmed: saved.dateConfirmed, state: saved.state).message
    }

    func saveAction(_ draft: ActionDraft, matterID: String) async -> Bool {
        guard let database else { return false }
        do {
            let previous = try await database.action(id: draft.id)
            try validateReminder(draft, previous: previous)
            let saved = try await database.saveAction(draft, matterID: matterID)
            await updateReminder(saved, previous: previous)
            selectedActionID = saved.id
            await reload()
            await refreshReminderStatus(updateMessage: false)
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "保存行动失败，请重试。"
            return false
        }
    }

    func setActionState(_ action: ActionRecord, state: String) async {
        guard let database else { return }
        do {
            try await database.setActionState(id: action.id, state: state)
            if let saved = try await database.action(id: action.id) {
                reminderMessage = await reminders.apply(actionID: saved.id, title: saved.title,
                    remindAt: saved.remindAt, dateConfirmed: saved.dateConfirmed, state: saved.state).message
            }
            await reload()
            await refreshReminderStatus(updateMessage: false)
        } catch { errorMessage = "更新待办失败，请重试。" }
    }

    func canRescheduleReminder(_ action: ActionRecord, now: Date = Date()) -> Bool {
        action.state == "active" && action.dateConfirmed
            && action.remindAt.map { $0 > now } == true
            && !pendingActionIDs.contains(action.id)
    }

    func rescheduleReminder(actionID: String) async -> ReminderResult {
        guard let database else {
            return ReminderResult(scheduled: false, message: "资料库不可用，无法重新安排提醒。")
        }
        guard reschedulingActionIDs.insert(actionID).inserted else {
            return ReminderResult(scheduled: false, message: "正在核对这条提醒，请稍候。")
        }
        defer { reschedulingActionIDs.remove(actionID) }
        do {
            await refreshReminderStatus(updateMessage: false)
            guard let action = try await database.action(id: actionID), action.state == "active",
                  action.dateConfirmed, let time = action.remindAt, time > Date() else {
                let result = ReminderResult(scheduled: false, message: "仅可重新安排待处理、已确认未来时间的行动提醒。请先检查行动的状态和时间。")
                reminderMessage = result.message
                return result
            }
            if pendingActionIDs.contains(actionID) {
                let result = ReminderResult(scheduled: true, message: "系统已有这条待发送提醒，无需重复安排。")
                reminderMessage = result.message
                return result
            }
            let result = await reminders.apply(actionID: action.id, title: action.title,
                remindAt: action.remindAt, dateConfirmed: action.dateConfirmed, state: action.state)
            // A permission prompt can suspend this operation while the action is edited elsewhere.
            if let current = try await database.action(id: actionID),
               current.state != action.state || current.dateConfirmed != action.dateConfirmed
                    || current.remindAt != action.remindAt {
                await updateReminder(current, previous: action)
                await refreshReminderStatus(updateMessage: false)
                let updated = ReminderResult(scheduled: pendingActionIDs.contains(actionID),
                    message: "行动已更新，已按最新状态核对系统提醒。")
                reminderMessage = updated.message
                return updated
            }
            await refreshReminderStatus(updateMessage: false)
            let restored = pendingActionIDs.contains(actionID)
            let message = restored ? "系统提醒已重新安排，请查看实际待发送时间。"
                : result.scheduled ? "系统尚未返回这条待发送提醒，请稍后重试。" : result.message
            reminderMessage = message
            return ReminderResult(scheduled: restored, message: message)
        } catch {
            await refreshReminderStatus(updateMessage: false)
            let result = ReminderResult(scheduled: false, message: "无法读取行动或重新安排提醒，请稍后重试。")
            reminderMessage = result.message
            return result
        }
    }

    func refreshReminderStatus(updateMessage: Bool = true) async {
        async let pending = reminders.pendingReminders()
        async let delivered = reminders.deliveredActionIDs()
        let (requests, received) = await (pending, delivered)
        pendingActionIDs = Set(requests.keys)
        pendingReminderDates = requests
        deliveredActionIDs = received
        if updateMessage { reminderMessage = await reminders.permissionMessage() }
    }

    func extractText(from file: LibraryFile) async throws -> DocumentTextResult {
        try await requireOrdinaryDocument(file)
        var root: URL?
        var documentURL: URL?
        if file.isAvailable, let source = sources.first(where: { $0.id == file.sourceID }) {
            do {
                let access = try FolderAccess.resolve(source)
                root = access.url
                documentURL = try FolderAccess.fileURL(relativePath: file.relativePath, root: access.url)
            } catch {
                root?.stopAccessingSecurityScopedResource()
                root = nil
            }
        }
        if documentURL == nil, let relative = file.managedCopyPath, let managedStore {
            documentURL = try managedStore.url(for: relative)
        }
        guard let documentURL else { throw AccessError.missing }
        let scopedRoot = root
        let worker = Task.detached(priority: .userInitiated) {
            defer { scopedRoot?.stopAccessingSecurityScopedResource() }
            return try DocumentTextExtractor.extract(from: documentURL, allowSensitiveName: true)
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try await requireOrdinaryDocument(file)
        return result
    }

    private func requireOrdinaryDocument(_ file: LibraryFile) async throws {
        guard let database, let current = try await database.file(id: file.id),
              !current.isPhoto, current.sensitivity == "normal" else { throw DocumentReadError.sensitive }
    }

    func suggestFacts(file: LibraryFile, text: String, allowedKeys: [String]) async throws -> [DocumentFactSuggestion] {
        try await requireOrdinaryDocument(file)
        let result = try await LocalFactAssistant.suggest(text: text, fileName: file.name,
            allowedKeys: allowedKeys, allowSensitiveName: true)
        try await requireOrdinaryDocument(file)
        return result
    }

    func saveDocumentText(file: LibraryFile, text: String) async -> Bool {
        guard let database else { return false }
        do {
            try await database.saveDocumentText(itemID: file.id, text: text, expectedFile: file)
            await reload()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "保存正文索引失败，请重试。"
            return false
        }
    }

    func indexSelectedDocument() async {
        guard let file = selectedFile, indexingID == nil else { return }
        indexingID = file.id
        errorMessage = nil
        defer { indexingID = nil }
        do {
            let result = try await extractText(from: file)
            _ = await saveDocumentText(file: file, text: result.text)
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func removeDocumentText(_ file: LibraryFile) async {
        guard let database else { return }
        do {
            try await database.deleteDocumentText(itemID: file.id)
            await reload()
        } catch { errorMessage = "移除正文索引失败，请重试。" }
    }

}

private enum DocumentReadError: LocalizedError {
    case sensitive
    var errorDescription: String? {
        "照片或已标记敏感的资料不读取正文、不交给模型处理。可手动填写必要字段；普通文件的隐私标记可在详情中调整。"
    }
}

private enum ReminderEditError: LocalizedError {
    case futureTimeRequired
    var errorDescription: String? { "请为已确认的提醒选择一个未来时间。" }
}
