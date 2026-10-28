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
            Button("添加文件夹…") { model.addFolders() }.keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.storageUnavailable)
        }
        CommandGroup(after: .textEditing) {
            Button("搜索资料") { model.searchFocusRequest += 1 }.keyboardShortcut("f")
        }
        CommandMenu("资料") {
            Button("系统预览") { model.quickLook() }.disabled(model.selectedFile == nil)
            Button("打开原件") { model.openSelected() }.keyboardShortcut("o")
                .disabled(model.selectedFile == nil)
            Button("在 Finder 中显示") { model.revealSelected() }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedFile == nil)
            Divider()
            Button("刷新来源") { model.refreshAll() }.keyboardShortcut("r")
                .disabled(model.sources.isEmpty || model.isScanning)
        }
    }
}
