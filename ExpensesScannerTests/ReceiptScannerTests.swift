import Foundation
import Testing
import UIKit
@testable import ExpensesScanner

/// The whole pipeline on a drawn receipt: Vision → rows → parser. Runs the real recogniser in the simulator.
struct ReceiptScannerTests {
    private func drawReceipt(_ lines: [(String, String)], width: CGFloat = 900) -> UIImage {
        let lineHeight: CGFloat = 70
        let size = CGSize(width: width, height: CGFloat(lines.count + 2) * lineHeight)
        let font = UIFont.monospacedSystemFont(ofSize: 40, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, line) in lines.enumerated() {
                let y = lineHeight * CGFloat(index + 1)
                (line.0 as NSString).draw(at: CGPoint(x: 50, y: y), withAttributes: attributes)
                let price = line.1 as NSString
                let priceWidth = price.size(withAttributes: attributes).width
                price.draw(at: CGPoint(x: width - 50 - priceWidth, y: y), withAttributes: attributes)
            }
        }
    }

    @Test func readsADrawnReceipt() async throws {
        let image = drawReceipt([
            ("CAFE CENTRAL", ""),
            ("Coffee", "3.50"),
            ("Croissant", "4.25"),
            ("Orange juice", "5.00"),
            ("TOTAL", "12.75"),
        ])
        let scanned = try await ReceiptScanner.scan([image])
        #expect(!scanned.photo.isEmpty)
        let rows = LineGrouper.rows(scanned.fragments)
        let receipt = ReceiptParser.parse(rows, currency: "USD")

        #expect(receipt.total == 1275, "rows: \(rows.map(\.text))")
        #expect(receipt.items.map(\.amount) == [350, 425, 500], "rows: \(rows.map(\.text))")
        #expect(receipt.mismatch == 0)
        // Every line knows where it is on the photo.
        #expect(receipt.items.allSatisfy { $0.box != nil })
    }

    /// A real photo of a contactless card slip (card and approval numbers blanked out), taken at an angle
    /// in sunlight with the issuer’s stamp over the amount, cropped to the slip as the document scanner does.
    @Test func readsAPhotographedCardSlip() async throws {
        let url = try #require(Bundle(for: PhotoBundle.self).url(forResource: "cardnet-sales-slip", withExtension: "jpg"))
        let image = try #require(UIImage(contentsOfFile: url.path))
        // The simulator recognises Japanese on the CPU, far slower than a phone: a smaller copy, and a
        // deadline so a stuck recogniser fails the test instead of the whole run.
        let page = try #require(ReceiptScanner.upright(image, width: 700).cgImage)
        log("OCR: recognising \(page.width)×\(page.height)")
        let fragments: [OCRFragment]? = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task.detached { once.resume(try? await ReceiptScanner.recognize(page)) }
            Task.detached {
                try? await Task.sleep(for: .seconds(240))
                once.resume(nil)
            }
        }
        let pieces = try #require(fragments, "OCR: the recogniser took over 4 minutes")
        let rows = LineGrouper.rows(pieces)
        for row in rows {
            log("OCR: \(row.fragments.map(\.text).joined(separator: " ¦ "))")
        }
        let receipt = ReceiptParser.parse(rows, currency: "EUR")
        log("OCR: parsed total=\(String(describing: receipt.total)) items=\(receipt.items.map(\.amount)) merchant=\(receipt.merchant ?? "-")")
        #expect(receipt.currency == "JPY")
        #expect(receipt.total == 3860)
        #expect(receipt.items.isEmpty)
    }

    @Test func stacksPagesIntoOnePhoto() async throws {
        let first = drawReceipt([("Coffee", "3.50")])
        let second = drawReceipt([("TOTAL", "3.50")])
        let scanned = try await ReceiptScanner.scan([first, second])
        let image = try #require(UIImage(data: scanned.photo))
        #expect(image.size.width == ReceiptScanner.pageWidth)
        // The second page's text sits in the lower half of the stacked photo.
        let total = try #require(scanned.fragments.first { $0.text.uppercased().contains("TOTAL") })
        #expect(total.box.y > 0.5)
    }
}

/// Finds the test bundle, where the photos are.
private final class PhotoBundle {}

/// Resumes a continuation the first time only.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Straight to stderr, unbuffered, so CI shows it even if a test hangs afterwards.
private func log(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
