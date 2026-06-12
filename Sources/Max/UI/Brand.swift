import SwiftUI
import AppKit

/// The Max brand mark — the sunglasses duck. Loaded from the app bundle's
/// Resources (DuckGlyph.png, transparent). Falls back to an SF Symbol if the
/// asset isn't present (e.g. `swift run` outside the .app bundle).
enum Brand {
    static let duck: NSImage? = {
        guard let url = Bundle.main.url(forResource: "DuckGlyph", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }()
}

/// Inline brand icon sized to `size`, using the duck if available.
struct DuckIcon: View {
    var size: CGFloat = 18

    var body: some View {
        if let duck = Brand.duck {
            Image(nsImage: duck)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "bubbles.and.sparkles.fill")
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
