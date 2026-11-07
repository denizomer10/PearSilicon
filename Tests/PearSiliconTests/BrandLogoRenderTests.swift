import AppKit
import SwiftUI
import XCTest
@testable import PearSilicon

@MainActor
final class BrandLogoRenderTests: XCTestCase {
    func testBrandLogoRendersVisiblePixels() throws {
        let content = PearBrand.logo
            .resizable()
            .interpolation(.high)
            .frame(width: 64, height: 64)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1

        let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no image")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        var visible = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.05 else { continue }
                // The logo is coloured against a clear/neutral background;
                // count pixels that differ from a near-white backdrop.
                if color.redComponent < 0.9 || color.greenComponent < 0.9 || color.blueComponent < 0.9 {
                    visible += 1
                }
            }
        }

        XCTAssertGreaterThan(visible, 100, "Brand logo rendered without visible coloured pixels")
    }
}
