import Photos
import UIKit
import YearBarcodeCore

enum LibraryAuthorization: Equatable {
    case notDetermined
    case full
    case limited
    case denied

    var access: LibraryAccess? {
        switch self {
        case .full: return .full
        case .limited: return .limited
        default: return nil
        }
    }
}

enum ImageRequestError: Error {
    /// The asset no longer exists or is no longer accessible.
    case unavailable
    /// The rendition lives in iCloud (or another provider) and could not be downloaded.
    case downloadFailed(Error?)
}

/// PhotoKit adapter. Reads only; never modifies or deletes library items.
final class PhotoLibraryService: @unchecked Sendable {
    private let imageManager = PHImageManager.default()

    var authorization: LibraryAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> LibraryAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .authorized: return .full
        case .limited: return .limited
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    // MARK: - Enumeration

    private func stillImageOptions(predicate: NSPredicate? = nil) -> PHFetchOptions {
        let options = PHFetchOptions()
        // Still images only: videos and screen recordings are never queried.
        var predicates = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let predicate { predicates.append(predicate) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        return options
    }

    /// Years represented by accessible capture dates.
    func availableYears(now: Date, timeZone: TimeZone) -> [Int] {
        let assets = PHAsset.fetchAssets(with: stillImageOptions())
        var dates: [Date?] = []
        dates.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in dates.append(asset.creationDate) }
        return SnapshotBuilder.availableYears(captureDates: dates, now: now, timeZone: timeZone)
    }

    /// Accessible still images for the year (through the cutoff), plus every
    /// accessible still image without a capture date so it can be counted.
    func descriptors(year: Int, cutoff: Date, timeZone: TimeZone) -> [LibraryAssetDescriptor] {
        let calendar = YearCalendar(timeZone: timeZone)
        let start = calendar.startOfYear(year)
        let end = min(calendar.startOfYear(year + 1), cutoff.addingTimeInterval(1))
        var result: [LibraryAssetDescriptor] = []
        // One pass over all still images: PhotoKit predicates cannot reliably
        // match a nil creation date, and undated items must be counted.
        PHAsset.fetchAssets(with: stillImageOptions()).enumerateObjects { asset, _, _ in
            let date = asset.creationDate
            if let date, date < start || date >= end { return }
            result.append(LibraryAssetDescriptor(assetID: asset.localIdentifier, captureDate: date, revision: Self.revision(of: asset)))
        }
        return result
    }

    /// PhotoKit has no public revision number. Edits change adjustments,
    /// dimensions, or the modification date of an adjusted asset; favoriting
    /// an unedited photo does not count as a change.
    static func revision(of asset: PHAsset) -> String {
        let modified = asset.hasAdjustments ? Int((asset.modificationDate ?? .distantPast).timeIntervalSince1970) : 0
        return "a\(asset.hasAdjustments ? 1 : 0)-\(asset.pixelWidth)x\(asset.pixelHeight)-m\(modified)"
    }

    func asset(id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    func assets(ids: [String]) -> [String: PHAsset] {
        var result: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            result[asset.localIdentifier] = asset
        }
        return result
    }

    // MARK: - Renditions

    /// The current photo-library rendition (edits applied; Live Photo still
    /// component), downloading from iCloud if needed.
    func image(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFit, allowNetwork: Bool = true) async throws -> UIImage {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .accurate
        options.isNetworkAccessAllowed = allowNetwork
        options.isSynchronous = false

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
                if let image {
                    continuation.resume(returning: image)
                    return
                }
                let error = info?[PHImageErrorKey] as? Error
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else if inCloud || error != nil {
                    continuation.resume(throwing: ImageRequestError.downloadFailed(error))
                } else {
                    continuation.resume(throwing: ImageRequestError.unavailable)
                }
            }
        }
    }

    /// Quick, single-callback thumbnail for pickers and lists.
    func thumbnail(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            imageManager.requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Original file bytes, only when already on the device (used for provenance cues).
    func localImageData(for asset: PHAsset) async -> (data: Data, uti: String?)? {
        let options = PHImageRequestOptions()
        options.version = .original
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                continuation.resume(returning: data.map { (data: $0, uti: uti) })
            }
        }
    }

    func originalFilename(for asset: PHAsset) -> String? {
        PHAssetResource.assetResources(for: asset).first { $0.type == .photo }?.originalFilename
    }
}
