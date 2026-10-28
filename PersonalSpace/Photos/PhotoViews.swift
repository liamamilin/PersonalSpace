import AppKit
import SwiftUI

private extension LibraryFile {
    var photoSortDate: Date { createdAt ?? .distantPast }
}

struct PhotosLibraryView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        PhotosLibraryContent(controller: model.photoLibrary)
    }
}

private struct PhotosLibraryContent: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var controller: PhotoLibraryController
    @State private var sortOrder = [KeyPathComparator(\LibraryFile.photoSortDate, order: .reverse)]

    private var photos: [LibraryFile] { model.files.filter(\.isPhoto).sorted(using: sortOrder) }

    var body: some View {
        VStack(spacing: 0) {
            PhotosAuthorizationHeader(controller: controller)
            Divider()
            if photos.isEmpty {
                if controller.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取已授权的照片…").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !model.search.isEmpty {
                    ContentUnavailableView.search(text: model.search)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("还没有照片资料", systemImage: "photo.on.rectangle",
                        description: Text("在上方连接或刷新照片图库。已有的对象关联会保留，重新授权后可继续预览。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Table(photos, selection: $model.selectedFileID, sortOrder: $sortOrder) {
                    TableColumn("照片", value: \.name) { file in
                        HStack(spacing: 10) {
                            PhotoThumbnail(file: file, controller: controller)
                                .frame(width: 48, height: 38)
                            Text(file.name).lineLimit(1).help(file.name)
                        }.frame(height: 46)
                    }.width(min: 170, ideal: 260)
                    TableColumn("拍摄日期", value: \.photoSortDate) { file in
                        Text(file.createdAt?.formatted(date: .numeric, time: .omitted) ?? "未知")
                            .foregroundStyle(.secondary)
                    }.width(min: 80, ideal: 100)
                    TableColumn("可用状态") { file in
                        Text(file.isAvailable && controller.canRead ? "已关联图库" : "等待访问图库")
                            .font(.callout).foregroundStyle(.secondary)
                    }.width(min: 90, ideal: 110)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first {
                        Button("预览照片") { model.selectedFileID = id; model.quickLook() }
                        Button("关联到对象…") {
                            model.selectedFileID = id
                            Task {
                                await model.reloadLinkedObjects()
                                model.showLinkSheet = true
                            }
                        }
                        Button("打开照片 App") { controller.openPhotosApp() }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { model.selectedFileID = id; model.quickLook() }
                }
                .onKeyPress(.space) {
                    guard model.selectedFileID != nil else { return .ignored }
                    model.quickLook()
                    return .handled
                }
                .onKeyPress(.return) {
                    guard model.selectedFileID != nil else { return .ignored }
                    model.quickLook()
                    return .handled
                }
            }
        }
    }
}

private struct PhotosAuthorizationHeader: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var controller: PhotoLibraryController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Label("照片图库", systemImage: "photo.on.rectangle").font(.headline)
                    Spacer()
                    actions
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("照片图库", systemImage: "photo.on.rectangle").font(.headline)
                    actions
                }
            }
            Text(controller.authorizationMessage).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("只读关联，不修改照片。预览只使用本机已有资源，不下载 iCloud 原件。")
                .font(.caption).foregroundStyle(.secondary)
            if !controller.canRead {
                Text("如已拒绝，请在「系统设置 › 隐私与安全性 › 照片」中允许 PersonalSpace，再点击连接。对象关联会保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if controller.isLoading { ProgressView().controlSize(.small) }
            if !controller.canRead {
                Button("连接照片图库", systemImage: "photo.badge.plus") { Task { await model.connectPhotos() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isLoading)
                    .accessibilityIdentifier("photos-connect")
            }
            Button("刷新照片", systemImage: "arrow.clockwise") { Task { await model.refreshPhotos() } }
                .disabled(controller.isLoading || !controller.canRead)
                .accessibilityIdentifier("photos-refresh")
        }
    }
}

private struct PhotoThumbnail: View {
    let file: LibraryFile
    @ObservedObject var controller: PhotoLibraryController
    @State private var image: NSImage?
    @State private var loading = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .accessibilityLabel(file.name + "缩略图")
            } else if loading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    .accessibilityLabel("照片缩略图暂不可用")
            }
        }
        .task(id: "\(file.id)|\(file.isAvailable)|\(controller.canRead)") {
            image = nil
            guard let identifier = file.photoLocalIdentifier, controller.canRead else { return }
            loading = true
            defer { loading = false }
            do {
                let loaded = try await controller.image(localIdentifier: identifier, large: false)
                try Task.checkCancellation()
                image = loaded
            } catch { }
        }
    }
}

struct PhotoDetailView: View {
    @EnvironmentObject private var model: LibraryModel
    let file: LibraryFile

    var body: some View {
        PhotoDetailContent(file: file, controller: model.photoLibrary)
    }
}

private struct PhotoDetailContent: View {
    @EnvironmentObject private var model: LibraryModel
    let file: LibraryFile
    @ObservedObject var controller: PhotoLibraryController
    @State private var image: NSImage?
    @State private var previewError: String?
    @State private var loading = false
    @State private var updatingSensitivity = false
    @State private var unlinking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.name).font(.headline).textSelection(.enabled)
                    Label("照片图库 · 只读关联", systemImage: "photo").font(.subheadline).foregroundStyle(.secondary)
                }
                preview
                ViewThatFits(in: .horizontal) {
                    HStack {
                        previewButton
                        openPhotosButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        previewButton
                        openPhotosButton
                    }
                }.controlSize(.small)
                Text("可在照片 App 中按文件名或拍摄日期查找这张照片。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("预览清晰度取决于本机已有资源；大图不可用时显示本机缩略预览。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("关联的对象").font(.headline)
                        Spacer()
                        Button("关联", systemImage: "link") { model.showLinkSheet = true }
                    }
                    if model.linkedObjects.isEmpty {
                        Text("尚未关联个人对象").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.linkedObjects) { object in
                        HStack {
                            Button(object.name) { model.showObject(object.id) }.buttonStyle(.link)
                            Spacer()
                            Button("解除关联", systemImage: "xmark") {
                                unlinking = true
                                Task {
                                    await model.unlink(file.id, from: object.id)
                                    unlinking = false
                                }
                            }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(unlinking)
                                .help("解除与「\(object.name)」的关联，保留照片")
                        }
                    }
                    Text("照片访问失效时保留对象关联；重新授权或刷新后可以恢复预览。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("隐私标记").font(.headline)
                    Picker("资料标记", selection: Binding(get: { file.sensitivity }, set: { value in
                        updatingSensitivity = true
                        Task {
                            await model.setSensitivity(file, state: value)
                            updatingSensitivity = false
                        }
                    })) {
                        Text("普通").tag("normal")
                        Text("疑似敏感").tag("suspected")
                        Text("敏感").tag("sensitive")
                    }.disabled(updatingSensitivity)
                    Text("照片只用于查看和关联，不做文字识别或正文索引。请继续使用专用工具保存密码与恢复码。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Text("照片信息").font(.headline)
                    property("原始文件名", value: file.name)
                    property("拍摄日期", value: file.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")
                    property("修改日期", value: file.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")
                    property("来源", value: "系统照片图库")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .task(id: file.id) { await model.reloadLinkedObjects() }
        .task(id: "\(file.id)|\(file.isAvailable)|\(controller.canRead)") {
            image = nil
            previewError = nil
            guard let identifier = file.photoLocalIdentifier else {
                previewError = "此照片的图库标识已不可用。已有对象关联会保留。"
                return
            }
            guard controller.canRead else {
                previewError = "当前无法访问照片图库。请连接照片图库或在系统设置中恢复授权。"
                return
            }
            loading = true
            defer { loading = false }
            do {
                let loaded = try await controller.image(localIdentifier: identifier, large: true)
                try Task.checkCancellation()
                image = loaded
            } catch is CancellationError { }
            catch { previewError = error.localizedDescription }
        }
    }

    @ViewBuilder private var preview: some View {
        if let image {
            Button { model.quickLook() } label: {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 280)
            }.buttonStyle(.plain).help("放大预览照片（空格）")
                .accessibilityLabel("预览照片：" + file.name)
        } else if loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取本机预览…").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 170)
        } else {
            ContentUnavailableView("照片预览暂不可用", systemImage: "photo.badge.exclamationmark",
                description: Text(previewError ?? "此照片可能不在本机，或已不在授权范围。请在照片 App 检查后刷新。"))
                .frame(minHeight: 170)
        }
    }

    private var previewButton: some View {
        Button("放大预览", systemImage: "arrow.up.left.and.arrow.down.right") { model.quickLook() }
            .disabled(image == nil)
    }

    private var openPhotosButton: some View {
        Button("打开照片 App", systemImage: "arrow.up.right.square") { controller.openPhotosApp() }
    }

    private func property(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PhotoPreviewSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var zoom = 1.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("照片预览").font(.headline)
                Spacer()
                Button("适应窗口") { zoom = 1 }
                Slider(value: $zoom, in: 1...4) { Text("缩放") }.frame(width: 120)
                Text(zoom, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
                Button("完成") { model.showPhotoPreview = false }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let image = model.photoPreviewImage {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: max(1, geometry.size.width - 32) * zoom,
                                   height: max(1, geometry.size.height - 32) * zoom)
                            .padding(16)
                            .accessibilityLabel("照片大图预览")
                    }
                }
            } else {
                ContentUnavailableView("照片预览暂不可用", systemImage: "photo.badge.exclamationmark",
                    description: Text("请关闭后重新选择照片，或连接照片图库后重试。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 520, idealWidth: 900, minHeight: 400, idealHeight: 650)
    }
}
