import Foundation

struct AssistantActionRequest: Identifiable {
    var id = UUID()
    let matterID: String
    let draft: ActionDraft
}

struct AssistantToolResult {
    let value: AssistantJSON
    let summary: String
    var needsUserInput = false
}

enum AssistantTools {
    private static func text(_ description: String) -> AssistantJSON {
        .object(["type": .string("string"), "description": .string(description)])
    }
    private static func choice(_ values: [String]) -> AssistantJSON {
        .object(["type": .string("string"), "enum": .array(values.map(AssistantJSON.string))])
    }
    private static func list(_ description: String) -> AssistantJSON {
        .object(["type": .string("array"), "items": text(description)])
    }
    private static func tool(_ name: String, _ description: String, _ fields: [String: AssistantJSON] = [:], _ required: [String] = []) -> AssistantJSON {
        .object(["type": .string("function"), "function": .object([
            "name": .string(name), "description": .string(description),
            "parameters": .object(["type": .string("object"), "properties": .object(fields),
                "required": .array(required.map(AssistantJSON.string))])])])
    }

    static let schema: AssistantJSON = .array([
        tool("library_info", "Read actual library counts, selected context, sources, scan and system reminder status."),
        tool("search_library", "Query stored records. Always use real IDs from results; file results include available originals and managed copies. Default limit 30, maximum 100; offset paginates.", [
            "entity": choice(["files", "objects", "matters", "actions", "sources"]),
            "query": text("Name/path keyword; empty means all. Actions can use a title keyword."),
            "source_id": text("Optional source ID"), "object_id": text("Optional object ID"),
            "matter_id": text("Optional matter ID"), "managed_only": .object(["type": .string("boolean")]),
            "inbox_only": .object(["type": .string("boolean")]),
            "search_body": .object(["type": .string("boolean"), "description": .string("Search only user-allowed saved full-text indexes in addition to names/paths")]),
            "sort": choice(["name", "kind", "modified", "size", "source"]), "ascending": .object(["type": .string("boolean")]),
            "limit": .object(["type": .string("integer")]), "offset": .object(["type": .string("integer")])], ["entity"]),
        tool("inspect_file", "Read metadata and object associations. read_body=true explicitly reads one non-sensitive PDF/image/text with existing local extraction; it does not save a full-text index.", [
            "item_id": text("Real item ID"), "read_body": .object(["type": .string("boolean")])], ["item_id"]),
        tool("file_operation", "Operate on actual indexed files, up to 30 IDs. import = 快速收纳 into 待整理/inbox: creates NEW imported item IDs, use returned IDs for subsequent links. archive = 保存托管副本 on the EXISTING record, does NOT enter inbox or create new items. Removal opens the existing confirmation, and linked imported files cannot be removed. No original deletion, rename or moving.", [
            "operation": choice(["show", "open", "preview", "reveal", "archive", "import", "remove", "index_text", "remove_text_index", "set_sensitivity"]),
            "item_ids": list("Real item ID"), "target": choice(["available", "original", "managed"]),
            "sensitivity": choice(["normal", "suspected", "sensitive"])], ["operation", "item_ids"]),
        tool("choose_files_and_import", "Open the system file picker, then copy user-selected files into inbox. User chooses actual files; do not invent paths."),
        tool("source_operation", "Choose folders in the system panel, refresh authorized folders, stop scans, reauthorize or remove a source. Scan is read-only, excludes hidden/package/symlink files. User must choose a folder before accessing a new location.", [
            "operation": choice(["choose", "refresh", "stop", "reauthorize", "remove"]), "source_id": text("Existing source ID; omit refresh to refresh all")], ["operation"]),
        tool("object_operation", "Create/update a personal object, show it, link/unlink existing files. Existing properties are preserved if omitted. Objects can be device or other. Creation and links are saved, originals unchanged.", [
            "operation": choice(["create", "update", "show", "link", "unlink"]), "object_id": text("Existing object ID except create"),
            "name": text("Object name"), "kind": choice(["device", "other"]), "notes": text("Notes"), "item_ids": list("Existing item ID")], ["operation"]),
        tool("prepare_matter", "Prepare an order/contract/warranty/subscription in the existing editor. This does NOT save: user reviews facts/dates and clicks Save. Editing preserves omitted fields and all other actions. When the user asks to recognize a receipt or fill its explicit facts, use recognize_item_id: existing on-device extraction fills supported candidate facts with exact source excerpts; prefer this to rewriting parsed facts yourself. Facts from AI are candidates. Allowed fact keys for warranty: product,merchant,purchase_date,warranty_end_date,warranty_terms; order: product,merchant,order_number,purchase_date,received_date,amount; contract: counterparty,contract_number,start_date,end_date,renewal_terms,cancellation_terms,amount; subscription: service,provider,start_date,next_billing_date,renewal_terms,cancellation_terms,amount. Reminder dates require user confirmation in action editor.", [
            "matter_id": text("Existing ID for editing; omit to create"), "kind": choice(["order", "contract", "warranty", "subscription"]),
            "title": text("Matter title"), "status": choice(["active", "completed"]), "object_id": text("Optional actual object ID; empty explicitly clears"),
            "item_ids": list("Attached real item IDs"), "recognize_item_id": text("Real attached file ID to explicitly recognize with the existing local extractor; no full-text index saved"), "notes": text("Matter notes"),
            "facts": .object(["type": .string("object"), "properties": .object(Dictionary(uniqueKeysWithValues:
                Set(MatterKind.allCases.flatMap(\.fieldKeys)).map { key in
                    (key, text(MatterKind.title(for: key) + (MatterKind.valueType(for: key) == "date" ? "，明确日期 YYYY-MM-DD；未知省略" : "，凭证中的明确文字；未知省略")))
                })), "additionalProperties": .bool(false)]),
            "actions": .object(["type": .string("array"), "items": .object(["type": .string("object"), "properties": .object([
                "id": text("Existing action ID when changing one"), "title": text("Action title"),
                "due_date": text("Optional YYYY-MM-DD"), "remind_at": text("Optional ISO8601 timestamp including timezone; user will confirm")]), "required": .array([.string("title")])])])]),
        tool("action_operation", "Prepare/edit one action in the existing review editor, complete, cancel or reschedule an existing action. prepare does not save until user clicks Save. Reschedule only confirmed future active dates with missing requests; no automatic historical recovery.", [
            "operation": choice(["prepare", "complete", "cancel", "reschedule"]), "action_id": text("Existing action ID, omit when preparing a new one"),
            "matter_id": text("Parent matter ID for new action"), "title": text("Action title"),
            "due_date": text("Optional YYYY-MM-DD"), "remind_at": text("Optional full ISO8601 with timezone; proposed time must be confirmed by user")], ["operation"]),
        tool("navigate", "Open an existing app page or settings. object/matter detail uses a real ID. Does not create records.", [
            "page": choice(["all", "inbox", "managed", "objects", "matters", "actions", "photos", "object", "matter", "source", "sources_settings", "backup_settings"]),
            "id": text("Object/matter/source ID for detail"), "search": text("Optional search keyword"),
            "sort": choice(["name", "kind", "modified", "size", "source"]), "ascending": .object(["type": .string("boolean")])], ["page"]),
        tool("photos_operation", "Connect/refresh PhotoKit with existing permission flow, or open Photos app. Reads local authorized metadata/previews only, no iCloud original download, no photo export or OCR.", [
            "operation": choice(["connect", "refresh", "open_app"])], ["operation"]),
        tool("backup_operation", "Export with system save panel, verify with system open panel, preview verified backup, open activation confirmation for a verified backup, or open settings to switch libraries. Never silently switches, overwrites, merges or deletes libraries.", [
            "operation": choice(["export", "verify", "preview_verified", "activate_verified", "switch_library"])], ["operation"])
    ])

    static func title(_ name: String) -> String {
        switch name {
        case "library_info": "核对资料库和系统状态"
        case "search_library": "查询资料"
        case "inspect_file": "查看文件内容和关联"
        case "file_operation": "处理所选文件"
        case "choose_files_and_import": "选择并收纳文件"
        case "source_operation": "处理文件夹来源"
        case "object_operation": "整理个人对象"
        case "prepare_matter": "准备事务草稿"
        case "action_operation": "处理行动与提醒"
        case "navigate": "打开应用页面"
        case "photos_operation": "处理照片访问"
        case "backup_operation": "处理备份与恢复"
        default: "无法识别的操作"
        }
    }
}
