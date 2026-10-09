import SwiftUI
import UIKit
import Vision
import VisionKit

/// A receipt ready to review: one photo (pages stacked top to bottom) and the text read off it.
struct ScannedReceipt {
    /// JPEG.
    var photo: Data
    /// Positions are in the stacked photo's coordinates.
    var fragments: [OCRFragment]
}

/// Reads receipts on the device. Nothing leaves the phone.
enum ReceiptScanner {
    /// Pages are scaled to this width before reading and stacking: sharp enough for small print,
    /// small enough to store.
    static let pageWidth: CGFloat = 1400

    /// Reads every page, stacks them into one tall photo and maps each piece of text into it.
    static func scan(_ pages: [UIImage]) async throws -> ScannedReceipt {
        let scaled = pages.map { upright($0, width: pageWidth) }
        var pageFragments: [[OCRFragment]] = []
        for page in scaled {
            guard let image = page.cgImage else { continue }
            pageFragments.append(try await recognize(image))
        }

        let totalHeight = scaled.reduce(0) { $0 + $1.size.height }
        guard totalHeight > 0 else { return ScannedReceipt(photo: Data(), fragments: []) }
        var fragments: [OCRFragment] = []
        var offset: CGFloat = 0
        for (page, pieces) in zip(scaled, pageFragments) {
            let share = Double(page.size.height / totalHeight)
            let start = Double(offset / totalHeight)
            for piece in pieces {
                var box = piece.box
                box.y = start + box.y * share
                box.height *= share
                fragments.append(OCRFragment(text: piece.text, box: box, slope: piece.slope.map { $0 * share }))
            }
            offset += page.size.height
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let stacked = UIGraphicsImageRenderer(size: CGSize(width: pageWidth, height: totalHeight), format: format).image { _ in
            var y: CGFloat = 0
            for page in scaled {
                page.draw(in: CGRect(x: 0, y: y, width: pageWidth, height: page.size.height))
                y += page.size.height
            }
        }
        return ScannedReceipt(photo: stacked.jpegData(compressionQuality: 0.6) ?? Data(), fragments: fragments)
    }

    /// The text Vision finds in `image`, positions normalised with the origin at the top left.
    static func recognize(_ image: CGImage) async throws -> [OCRFragment] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Language correction "fixes" prices and codes; receipts need the characters as printed.
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            return (request.results ?? []).compactMap { observation -> OCRFragment? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                // The text's own corners show how the line is tilted (origin bottom left, so flip the sign).
                let run = observation.topRight.x - observation.topLeft.x
                let slope = run > 0.02 ? -Double(observation.topRight.y - observation.topLeft.y) / Double(run) : nil
                return OCRFragment(
                    text: candidate.string,
                    box: OCRBox(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                    slope: slope
                )
            }
        }.value
    }

    /// The image redrawn upright (photos carry an orientation flag) at the given width.
    static func upright(_ image: UIImage, width: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let target = CGSize(width: width, height: (size.height * width / size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Apple's document camera: finds the receipt's edges, straightens it, and takes several pages for a
/// long one. Not available in the simulator.
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onCancel: () -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onScan: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}
