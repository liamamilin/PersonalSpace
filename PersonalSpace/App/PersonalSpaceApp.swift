import SwiftUI

@main
struct PersonalSpaceApp: App {
    @StateObject private var model = LibraryModel()
    var body: some Scene {
        WindowGroup("PersonalSpace", id: "library") {
            LibraryView().environmentObject(model)
        }
        .defaultSize(width: 1160, height: 740)
        .commands { LibraryCommands(model: model) }
        Settings {
            SourcesView().environmentObject(model)
        }
    }
}

struct LibraryCommands: Commands {
    @ObservedObject var model: LibraryModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.isMattersList || model.isActionsList ? "新建事务…" : "新建个人对象…") {
                if model.isMattersList || model.isActionsList { model.createOrder() }
                else { model.createObject() }
            }.keyboardShortcut("n")
                .disabled(model.storageUnavailable)
            Button("新建事务…") { model.createMatter(kind: .order) }.keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.storageUnavailable)
            Button("添加文件夹…") { model.addFolders() }.keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.storageUnavailable)
        }
        CommandGroup(after: .textEditing) {
            Button("搜索资料") { model.searchFocusRequest += 1 }.keyboardShortcut("f")
        }
        CommandMenu("资料") {
            Button("系统预览") { model.quickLook() }.disabled(model.selectedFile == nil)
            Button("打开可用文件") { model.openSelected() }.keyboardShortcut("o")
                .disabled(model.selectedFile == nil)
            Button("在 Finder 中显示") { model.revealSelected() }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedFile == nil)
            Button("关联到对象…") { model.showLinkSheet = true }.disabled(model.selectedFile == nil)
            Button("从资料创建事务…") { model.createMatter(kind: .order) }.disabled(model.selectedFile == nil || !model.isFileList)
            Button("保存副本到资料库") { Task { await model.archiveSelected() } }
                .disabled(model.selectedFile == nil || model.selectedFile?.managedCopyPath != nil || model.archivingID != nil)
            Divider()
            Button("刷新来源") { model.refreshAll() }.keyboardShortcut("r")
                .disabled(model.sources.isEmpty || model.isScanning)
        }
    }
}
