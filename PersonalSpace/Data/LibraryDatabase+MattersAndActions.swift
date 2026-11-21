import Foundation
import GRDB

extension LibraryDatabase {
    func matters(search: String = "") async throws -> [MatterRecord] {
        try await queue.read { db in
            var conditions = ["1=1"]
            var arguments = StatementArguments()
            for word in search.split(whereSeparator: \.isWhitespace).map(String.init) {
                let escaped = Self.escapedSearch(word)
                conditions.append("(m.title LIKE ? ESCAPE '\\' OR m.notes LIKE ? ESCAPE '\\')")
                arguments += ["%\(escaped)%", "%\(escaped)%"]
            }
            return try MatterRecord.fetchAll(db, sql: """
                SELECT m.*, (SELECT COUNT(*) FROM matter_item mi WHERE mi.matterID=m.id) AS itemCount
                FROM matter m WHERE \(conditions.joined(separator: " AND "))
                ORDER BY m.updatedAt DESC, m.id
                """, arguments: arguments)
        }
    }

    func matter(id: String) async throws -> MatterRecord? {
        try await queue.read { db in
            try MatterRecord.fetchOne(db, sql: """
                SELECT m.*, (SELECT COUNT(*) FROM matter_item mi WHERE mi.matterID=m.id) AS itemCount
                FROM matter m WHERE m.id=?
                """, arguments: [id])
        }
    }

    func facts(matterID: String) async throws -> [FactRecord] {
        try await queue.read { db in
            try FactRecord.fetchAll(db, sql: "SELECT * FROM fact WHERE matterID=? ORDER BY rowid",
                                    arguments: [matterID])
        }
    }

    func actions(matterID: String? = nil) async throws -> [ActionRecord] {
        try await queue.read { db in
            let condition = matterID == nil ? "1=1" : "a.matterID=?"
            let arguments: StatementArguments = matterID.map { [$0] } ?? []
            return try ActionRecord.fetchAll(db, sql: """
                SELECT a.*, m.title AS matterTitle FROM action a LEFT JOIN matter m ON m.id=a.matterID
                WHERE \(condition)
                ORDER BY CASE a.state WHEN 'active' THEN 0 WHEN 'needs_date' THEN 1 ELSE 2 END,
                    a.remindAt IS NULL, a.remindAt, a.updatedAt DESC, a.id
                """, arguments: arguments)
        }
    }

    func action(id: String) async throws -> ActionRecord? {
        try await queue.read { db in
            try Self.fetchAction(db, id: id)
        }
    }

    // Saving the editor is atomic: failed links/facts cannot leave a half-saved order or reminder.
    // Only submitted actions change; omitted rows retain their IDs, dates and state.
    @discardableResult
    func saveMatter(_ draft: MatterDraft) async throws -> [ActionRecord] {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let facts = draft.facts.compactMap { fact -> FactDraft? in
            var cleaned = fact
            cleaned.valueText = fact.valueText.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.valueText.isEmpty ? nil : cleaned
        }
        guard !draft.id.isEmpty, !title.isEmpty, ["order", "contract", "warranty", "subscription"].contains(draft.kind),
              ["active", "completed"].contains(draft.status),
              facts.allSatisfy({ !$0.id.isEmpty && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && ["text", "date", "amount"].contains($0.valueType)
                  && ["candidate", "confirmed"].contains($0.state)
                  && ["ocr", "model", "user"].contains($0.origin)
                  && ($0.valueType != "date" || Self.isValidCalendarDate($0.valueText)) }) else {
            throw LibraryDataError.invalidMatter
        }
        guard Set(draft.actions.map(\.id)).count == draft.actions.count else {
            throw LibraryDataError.invalidAction
        }
        for action in draft.actions { try Self.validateAction(action) }
        return try await queue.write { db in
            let now = Date()
            try db.execute(sql: """
                INSERT INTO matter(id, kind, title, status, objectID, notes, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, title=excluded.title,
                    status=excluded.status, objectID=excluded.objectID, notes=excluded.notes,
                    updatedAt=excluded.updatedAt
                """, arguments: [draft.id, draft.kind, title, draft.status, draft.objectID, draft.notes, now, now])
            try db.execute(sql: "DELETE FROM matter_item WHERE matterID=?", arguments: [draft.id])
            for itemID in Set(draft.itemIDs) {
                try db.execute(sql: "INSERT INTO matter_item(matterID, itemID) VALUES (?, ?)",
                               arguments: [draft.id, itemID])
            }
            try db.execute(sql: "DELETE FROM fact WHERE matterID=?", arguments: [draft.id])
            for fact in facts {
                try db.execute(sql: """
                    INSERT INTO fact(id, matterID, key, valueText, valueType, state, sourceItemID, sourceExcerpt, origin)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [fact.id, draft.id, fact.key, fact.valueText, fact.valueType,
                        fact.state, fact.sourceItemID, fact.sourceExcerpt, fact.origin])
            }
            return try draft.actions.map { try Self.saveAction(db, draft: $0, matterID: draft.id, now: now) }
        }
    }

    func saveAction(_ draft: ActionDraft, matterID: String) async throws -> ActionRecord {
        try Self.validateAction(draft)
        return try await queue.write { db in
            try Self.saveAction(db, draft: draft, matterID: matterID, now: Date())
        }
    }

    private static func validateAction(_ action: ActionDraft) throws {
        guard !action.id.isEmpty, !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["needs_date", "active", "done", "cancelled"].contains(action.state),
              action.dueDate?.timeIntervalSince1970.isFinite != false,
              action.remindAt?.timeIntervalSince1970.isFinite != false else {
            throw LibraryDataError.invalidAction
        }
    }

    private static func saveAction(_ db: Database, draft: ActionDraft, matterID: String, now: Date) throws -> ActionRecord {
        let existing = try fetchAction(db, id: draft.id)
        guard existing == nil || existing?.matterID == matterID else { throw LibraryDataError.invalidAction }
        var cleaned = draft
        cleaned.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.dateConfirmed || draft.remindAt == nil {
            cleaned.dateConfirmed = false
            cleaned.remindAt = nil
            if !["done", "cancelled"].contains(draft.state) { cleaned.state = "needs_date" }
        } else if draft.state == "needs_date" { cleaned.state = "active" }
        if let existing, ActionDraft(existing) == cleaned { return existing }
        try db.execute(sql: """
            INSERT INTO action(id, matterID, title, dueDate, remindAt, state, dateConfirmed, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, dueDate=excluded.dueDate,
                remindAt=excluded.remindAt, state=excluded.state, dateConfirmed=excluded.dateConfirmed,
                updatedAt=excluded.updatedAt
            """, arguments: [cleaned.id, matterID, cleaned.title, cleaned.dueDate, cleaned.remindAt,
                cleaned.state, cleaned.dateConfirmed, now, now])
        guard let saved = try fetchAction(db, id: draft.id) else { throw LibraryDataError.invalidAction }
        return saved
    }

    func setActionState(id: String, state: String) async throws {
        guard ["needs_date", "active", "done", "cancelled"].contains(state) else {
            throw LibraryDataError.invalidAction
        }
        try await queue.write { db in
            guard let action = try Self.fetchAction(db, id: id) else { throw LibraryDataError.invalidAction }
            let normalized = state == "active" && (!action.dateConfirmed || action.remindAt == nil)
                ? "needs_date" : state
            try db.execute(sql: "UPDATE action SET state=?, updatedAt=? WHERE id=?",
                           arguments: [normalized, Date(), id])
        }
    }

    private static func fetchAction(_ db: Database, id: String) throws -> ActionRecord? {
        try ActionRecord.fetchOne(db, sql: """
            SELECT a.*, m.title AS matterTitle FROM action a LEFT JOIN matter m ON m.id=a.matterID WHERE a.id=?
            """, arguments: [id])
    }

    private static func isValidCalendarDate(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
            return false
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

}
