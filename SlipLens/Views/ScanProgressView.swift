import SwiftUI

// MARK: - ScanProgressView

public struct ScanProgressView: View {
    @Bindable var viewModel: ExpenseTrackerViewModel

    public init(viewModel: ExpenseTrackerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("กำลังสแกนคลังรูปภาพ (\(viewModel.selectedMonthDisplayTitle))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("ยกเลิก", role: .destructive) {
                    viewModel.cancelScan()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            ProgressView(value: viewModel.scanFractionCompleted)
                .tint(.blue)

            HStack(spacing: 16) {
                Label(
                    "\(viewModel.processedCount) / \(viewModel.totalAssetsToScan) รูป",
                    systemImage: "photo.on.rectangle.angled"
                )
                Spacer()
                Label(
                    "พบสลิปใหม่ \(viewModel.matchedNewSlipsCount)",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)

                if viewModel.skippedDuplicatesCount > 0 {
                    Label(
                        "ข้ามซ้ำ \(viewModel.skippedDuplicatesCount)",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - AssetThumbnailView

/// Asynchronously loads and displays a `PHAsset` image using its `localIdentifier`.
public struct AssetThumbnailView: View {
    let localIdentifier: String
    let targetSize: CGSize
    let cornerRadius: CGFloat

    @State private var loadedImage: UIImage?
    @State private var didFail: Bool = false

    public init(
        localIdentifier: String,
        targetSize: CGSize = CGSize(width: 160, height: 160),
        cornerRadius: CGFloat = 10
    ) {
        self.localIdentifier = localIdentifier
        self.targetSize = targetSize
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.12))

            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: targetSize.width, height: targetSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else if didFail {
                Image(systemName: "doc.text.image")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: targetSize.width, height: targetSize.height)
        .task(id: localIdentifier) {
            didFail = false
            do {
                let pixelScale: CGFloat = 2.0
                let requestSize = CGSize(
                    width: targetSize.width * pixelScale,
                    height: targetSize.height * pixelScale
                )
                loadedImage = try await PhotoLibraryService.shared.loadUIImage(
                    localIdentifier: localIdentifier,
                    targetSize: requestSize
                )
            } catch {
                didFail = true
            }
        }
    }
}
