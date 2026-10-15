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
