import AppKit
import SwiftUI

/// SwiftUI's image-name lookup does not reliably resolve files inside a SwiftPM
/// resource bundle in a packaged (and translocated) app. Load the PNG through
/// the bundle URL instead so the logo is always visible.
enum PearBrand {
    static let logo: Image = {
        let url = Bundle.module.url(forResource: "PearLogo", withExtension: "png")
            ?? Bundle.main.url(forResource: "PearLogo", withExtension: "png")
        if let url, let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }
        return Image(systemName: "leaf.fill")
    }()
}
