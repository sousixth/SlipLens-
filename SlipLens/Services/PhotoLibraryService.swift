import Foundation
import Photos
import UIKit
import CoreGraphics

// MARK: - PhotoLibraryError

public enum PhotoLibraryError: LocalizedError, Sendable {
    case permissionDenied
    case assetNotFound
    case imageDecodingFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Photo Library access is required to scan your monthly slips and receipts. Please enable access in Settings."
        case .assetNotFound:
            return "The original image could not be found in your Photo Library."
        case .imageDecodingFailed:
            return "Failed to decode image data from PhotoKit."
        }
    }
}

// MARK: - ScanProgressUpdate

public struct ScanProgressUpdate: Sendable {
    public let processedCount: Int
    public let totalAssets: Int
    public let matchedCount: Int
    public let skippedDuplicateCount: Int
    public let latestCandidate: ScannedDocumentCandidate?

    public var fractionCompleted: Double {
        guard totalAssets > 0 else { return 0.0 }
        return min(1.0, Double(processedCount) / Double(totalAssets))
    }

    public init(
        processedCount: Int,
        totalAssets: Int,
        matchedCount: Int,
        skippedDuplicateCount: Int,
        latestCandidate: ScannedDocumentCandidate? = nil
    ) {
        self.processedCount = processedCount
        self.totalAssets = totalAssets
        self.matchedCount = matchedCount
        self.skippedDuplicateCount = skippedDuplicateCount
        self.latestCandidate = latestCandidate
    }
}

// MARK: - AssetMetadataSnapshot

private struct AssetMetadataSnapshot: Sendable {
    let localIdentifier: String
    let creationDate: Date
    let pixelWidth: Int
    let pixelHeight: Int
}

// MARK: - PhotoLibraryService

public final class PhotoLibraryService: Sendable {

    public static let shared = PhotoLibraryService()

    private let scannerService: SlipScannerService

    public init(scannerService: SlipScannerService = .shared) {
        self.scannerService = scannerService
    }

    // MARK: - Authorization

    public func currentAuthorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public func ensureAuthorization() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let grantedStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard grantedStatus == .authorized || grantedStatus == .limited else {
                throw PhotoLibraryError.permissionDenied
            }
        case .denied, .restricted:
            throw PhotoLibraryError.permissionDenied
        @unknown default:
            throw PhotoLibraryError.permissionDenied
        }
    }

    // MARK: - Monthly Batch Scanner

    /// Fetches all image assets created during the given `(year, month)` in `Asia/Bangkok` time,
    /// filters out non-candidates/duplicates, runs Vision OCR + Mini-QR detection, and streams progress updates.
    public func scanMonth(
        year: Int,
        month: Int,
        deduplicationIndex: DeduplicationIndex,
        onProgress: @escaping @Sendable (ScanProgressUpdate) async -> Void
    ) async throws -> [ScannedDocumentCandidate] {
        try await ensureAuthorization()

        let assetSnapshots = fetchAssetSnapshots(year: year, month: month)
        let totalAssets = assetSnapshots.count

        if totalAssets == 0 {
            await onProgress(
                ScanProgressUpdate(
                    processedCount: 0,
                    totalAssets: 0,
                    matchedCount: 0,
                    skippedDuplicateCount: 0
                )
            )
            return []
        }

        var workingDedup = deduplicationIndex
        var discoveredCandidates: [ScannedDocumentCandidate] = []
        var processedCount = 0
        var skippedDuplicateCount = 0

        for snapshot in assetSnapshots {
            try Task.checkCancellation()

            processedCount += 1

            // 1. Skip if this exact PHAsset.localIdentifier was already scanned or ignored
            if workingDedup.assetIdentifiers.contains(snapshot.localIdentifier) {
                skippedDuplicateCount += 1
                await onProgress(
                    ScanProgressUpdate(
                        processedCount: processedCount,
                        totalAssets: totalAssets,
                        matchedCount: discoveredCandidates.count,
                        skippedDuplicateCount: skippedDuplicateCount
                    )
                )
                continue
            }

            // 2. Fast aspect-ratio check to skip panoramic landscapes or tiny icons
            guard scannerService.passesAspectRatioPrecheck(
                pixelWidth: snapshot.pixelWidth,
                pixelHeight: snapshot.pixelHeight
            ) else {
                await onProgress(
                    ScanProgressUpdate(
                        processedCount: processedCount,
                        totalAssets: totalAssets,
                        matchedCount: discoveredCandidates.count,
                        skippedDuplicateCount: skippedDuplicateCount
                    )
                )
                continue
            }

            // 3. Load CGImage optimized for Vision OCR (~1800px max dimension)
            guard let cgImage = try? await loadCGImageForOCR(localIdentifier: snapshot.localIdentifier) else {
                await onProgress(
                    ScanProgressUpdate(
                        processedCount: processedCount,
                        totalAssets: totalAssets,
                        matchedCount: discoveredCandidates.count,
                        skippedDuplicateCount: skippedDuplicateCount
                    )
                )
                continue
            }

            // 4. Perform Vision OCR + Barcode Extraction
            do {
                let candidate = try await scannerService.scanImage(
                    cgImage: cgImage,
                    assetLocalIdentifier: snapshot.localIdentifier,
                    fallbackDate: snapshot.creationDate
                )

                // 5. Deduplicate by Transaction Ref ID or (Date + Amount + Normalized Recipient)
                if workingDedup.contains(candidate) {
                    skippedDuplicateCount += 1
                    workingDedup.assetIdentifiers.insert(snapshot.localIdentifier)
                    await onProgress(
                        ScanProgressUpdate(
                            processedCount: processedCount,
                            totalAssets: totalAssets,
                            matchedCount: discoveredCandidates.count,
                            skippedDuplicateCount: skippedDuplicateCount
                        )
                    )
                } else {
                    workingDedup.insert(candidate)
                    discoveredCandidates.append(candidate)
                    await onProgress(
                        ScanProgressUpdate(
                            processedCount: processedCount,
                            totalAssets: totalAssets,
                            matchedCount: discoveredCandidates.count,
                            skippedDuplicateCount: skippedDuplicateCount,
                            latestCandidate: candidate
                        )
                    )
                }
            } catch {
                // Non-slip photo or unparseable image; continue scanning remaining photos
                await onProgress(
                    ScanProgressUpdate(
                        processedCount: processedCount,
                        totalAssets: totalAssets,
                        matchedCount: discoveredCandidates.count,
                        skippedDuplicateCount: skippedDuplicateCount
                    )
                )
            }
        }

        return discoveredCandidates
    }

    // MARK: - PHAsset Querying

    private func fetchAssetSnapshots(year: Int, month: Int) -> [AssetMetadataSnapshot] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current

        guard let startDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let endDate = calendar.date(byAdding: .month, value: 1, to: startDate) else {
            return []
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate < %@",
            PHAssetMediaType.image.rawValue,
            startDate as NSDate,
            endDate as NSDate
        )
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        var snapshots: [AssetMetadataSnapshot] = []
        snapshots.reserveCapacity(fetchResult.count)

        fetchResult.enumerateObjects { asset, _, _ in
            snapshots.append(
                AssetMetadataSnapshot(
                    localIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate ?? startDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight
                )
            )
        }

        return snapshots
    }

    // MARK: - Image Loading for OCR & UI Thumbnails

    /// Loads an upright `CGImage` scaled to a maximum dimension of 1800px for fast, accurate Vision OCR.
    public func loadCGImageForOCR(
        localIdentifier: String,
        maxDimension: CGFloat = 1800
    ) async throws -> CGImage {
        let uiImage = try await loadUIImage(
            localIdentifier: localIdentifier,
            targetSize: CGSize(width: maxDimension, height: maxDimension),
            deliveryMode: .highQualityFormat
        )
        guard let cgImage = Self.normalizedCGImage(from: uiImage) else {
            throw PhotoLibraryError.imageDecodingFailed
        }
        return cgImage
    }

    /// Loads a `UIImage` thumbnail or full preview for SwiftUI views (`TransactionReviewListView`, `TransactionDetailView`).
    public func loadUIImage(
        localIdentifier: String,
        targetSize: CGSize = CGSize(width: 600, height: 600),
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic
    ) async throws -> UIImage {
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard let asset = fetchResult.firstObject else {
            throw PhotoLibraryError.assetNotFound
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let resumeGuard = ResumeOnceGuard()

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if isCancelled {
                    if resumeGuard.tryClaim() {
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                }

                if let error = info?[PHImageErrorKey] as? Error {
                    if resumeGuard.tryClaim() {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded && deliveryMode == .highQualityFormat {
                    return
                }

                if let image {
                    if resumeGuard.tryClaim() {
                        continuation.resume(returning: image)
                    }
                } else if !isDegraded {
                    if resumeGuard.tryClaim() {
                        continuation.resume(throwing: PhotoLibraryError.imageDecodingFailed)
                    }
                }
            }
        }
    }

    /// Redraws a `UIImage` into an upright `.up` orientation `CGImage` so Vision bounding boxes align with visual rows.
    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.cgImage
    }
}

// MARK: - ResumeOnceGuard

private final class ResumeOnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func tryClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return false }
        hasResumed = true
        return true
    }
}

