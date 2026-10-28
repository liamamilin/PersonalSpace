import AppKit
import Combine
import Foundation
import Photos

@MainActor
final class PhotoLibraryController: ObservableObject {
    static let sourceID = "photos"

    @Published private(set) var authorizationMessage = "尚未连接照片图库。"
    @Published private(set) var canRead = false
    @Published private(set) var isLoading = false

    init() {
        refreshAuthorization()
    }

    /// This query never prompts for permission or fetches library contents.
    func refreshAuthorization() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        canRead = Self.hasReadAuthorization(status)
        switch status {
        case .notDetermined:
            authorizationMessage = "尚未连接照片图库。点击「连接照片图库」后，系统才会请求授权。"
        case .authorized:
            authorizationMessage = "已获照片访问授权。仅展示本机可用的照片，不修改图库，不下载 iCloud 原片。"
        case .limited:
            authorizationMessage = "仅可读取已授权的照片。本机未下载的内容暂不可预览。"
        case .denied:
            authorizationMessage = "照片访问未获授权。可在系统设置的「隐私与安全性 → 照片」中允许访问；文件资料库仍可使用。"
        case .restricted:
            authorizationMessage = "此 Mac 的照片访问受系统限制；文件资料库仍可使用。"
        @unknown default:
            authorizationMessage = "无法确认照片授权。请检查系统设置；文件资料库仍可使用。"
        }
    }

    /// Called only by the user's Connect button. PhotoKit offers readWrite and
    /// addOnly access levels; all operations here use its read APIs exclusively.
    func requestAccess() async -> Bool {
        refreshAuthorization()
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else {
            return canRead
        }
        isLoading = true
        defer { isLoading = false }
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refreshAuthorization()
        return canRead
    }

    func fetchPhotos(limit: Int = 500) async throws -> [ScannedPhoto] {
        try Task.checkCancellation()
        try requireAccess()
        guard limit > 0 else { return [] }
        isLoading = true
        defer {
            isLoading = false
            if !Self.hasReadAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite)) {
                refreshAuthorization()
            }
        }
        // Keep a user refresh bounded even if a caller supplies an excessive
        // limit. No asset bytes are requested while reading this metadata.
        let fetchLimit = min(limit, 5_000)
        let work = Task.detached(priority: .userInitiated) {
            try Self.readMetadata(limit: fetchLimit)
        }
        let photos = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        try requireAccess()
        if photos.count == fetchLimit {
            authorizationMessage += " 本次最多显示最近 \(fetchLimit) 张照片。"
        }
        return photos
    }

    func image(localIdentifier: String, large: Bool = false) async throws -> NSImage {
        try Task.checkCancellation()
        try requireAccess()
        defer { refreshAuthorization() }
        guard !localIdentifier.isEmpty else { throw PhotoLibraryError.missingAsset }
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = false
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: fetchOptions).firstObject,
              asset.mediaType == .image, !asset.isHidden else { throw PhotoLibraryError.missingAsset }
        // A large local rendition can be unavailable while Photos still has a
        // cached thumbnail. Try that cache once; never enable iCloud downloads.
        let dimensions: [CGFloat] = large ? [2_048, 320] : [320]
        for dimension in dimensions {
            try Task.checkCancellation()
            try requireAccess()
            do {
                let image = try await requestLocalImage(asset: asset, dimension: dimension)
                try Task.checkCancellation()
                try requireAccess()
                return image
            } catch PhotoLibraryError.localResourceUnavailable where large && dimension == 2_048 {
                continue
            }
        }
        throw PhotoLibraryError.localResourceUnavailable
    }

    private func requestLocalImage(asset: PHAsset, dimension: CGFloat) async throws -> NSImage {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        // HighQualityFormat delivers one completion, so there is no opportunistic
        // degraded callback to accidentally resume this continuation twice.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.version = .current
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImage(for: asset,
                targetSize: CGSize(width: dimension, height: dimension),
                contentMode: .aspectFit, options: options) { image, info in
                guard Self.hasReadAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
                    continuation.resume(throwing: PhotoLibraryError.authorization)
                    return
                }
                if (info?[PHImageCancelledKey] as? NSNumber)?.boolValue == true {
                    continuation.resume(throwing: CancellationError())
                } else if let error = info?[PHImageErrorKey] as? NSError {
                    continuation.resume(throwing: Self.imageError(error))
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    // Missing iCloud resources are a normal, explicit failure.
                    // Never turn on network access or export an asset to disk.
                    continuation.resume(throwing: PhotoLibraryError.localResourceUnavailable)
                }
            }
        }
        try Task.checkCancellation()
        try requireAccess()
        return image
    }

    private nonisolated static func imageError(_ error: NSError) -> Error {
        if error.domain == PHPhotosErrorDomain {
            switch PHPhotosError.Code(rawValue: error.code) {
            case .userCancelled:
                return CancellationError()
            case .accessRestricted, .accessUserDenied:
                return PhotoLibraryError.authorization
            case .identifierNotFound:
                return PhotoLibraryError.missingAsset
            case .networkAccessRequired, .missingResource, .invalidResource:
                return PhotoLibraryError.localResourceUnavailable
            default:
                return PhotoLibraryError.imageRequestFailed
            }
        }
        if error.domain == NSCocoaErrorDomain,
           [CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue].contains(error.code) {
            return PhotoLibraryError.localResourceUnavailable
        }
        return PhotoLibraryError.imageRequestFailed
    }

    /// Opens the app itself. PhotoKit does not provide a supported API here for
    /// navigating Photos to this particular local identifier.
    func openPhotosApp() {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") else {
            authorizationMessage = "未找到系统「照片」App。请从应用程序文件夹手动打开。"
            return
        }
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.openApplication(at: application,
                    configuration: NSWorkspace.OpenConfiguration())
            } catch {
                authorizationMessage = "未能打开系统「照片」App。请从应用程序文件夹手动打开。"
            }
        }
    }

    private func requireAccess() throws {
        refreshAuthorization()
        guard canRead else { throw PhotoLibraryError.authorization }
    }

    private nonisolated static func hasReadAuthorization(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    private nonisolated static func readMetadata(limit: Int) throws -> [ScannedPhoto] {
        try Task.checkCancellation()
        guard hasReadAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
            throw PhotoLibraryError.authorization
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        options.wantsIncrementalChangeDetails = false
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var photos: [ScannedPhoto] = []
        photos.reserveCapacity(assets.count)
        for index in 0..<assets.count {
            try Task.checkCancellation()
            guard hasReadAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
                throw PhotoLibraryError.authorization
            }
            let photo: ScannedPhoto = autoreleasepool {
                let asset = assets.object(at: index)
                let resources = PHAssetResource.assetResources(for: asset)
                let resource = resources.first { $0.type == .photo || $0.type == .fullSizePhoto } ?? resources.first
                let filename: String?
                if #available(macOS 27.0, *) {
                    filename = resource?.filename
                } else {
                    filename = resource?.originalFilename
                }
                let fallback = asset.creationDate.map { "照片 " + $0.formatted(date: .numeric, time: .shortened) } ?? "照片"
                let name = filename.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
                return ScannedPhoto(localIdentifier: asset.localIdentifier, name: name,
                    createdAt: asset.creationDate, modifiedAt: asset.modificationDate)
            }
            photos.append(photo)
        }
        guard hasReadAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
            throw PhotoLibraryError.authorization
        }
        return photos
    }
}

private enum PhotoLibraryError: LocalizedError {
    case authorization, missingAsset, localResourceUnavailable, imageRequestFailed

    var errorDescription: String? {
        switch self {
        case .authorization:
            "照片访问未获授权或已失效。请在系统设置的「隐私与安全性 → 照片」中允许访问；文件资料库仍可使用。"
        case .missingAsset:
            "此照片目前不可用，可能已被移除、隐藏，或不在授权范围内。请刷新照片来源。"
        case .localResourceUnavailable:
            "此照片在本机没有可用的预览资源，或本地资源读取失败。PersonalSpace 不会下载 iCloud 原片；可在「照片」App 中确认后重试。"
        case .imageRequestFailed:
            "未能读取此照片的预览。请在「照片」App 中确认图库可用后，刷新来源并重试。"
        }
    }
}
