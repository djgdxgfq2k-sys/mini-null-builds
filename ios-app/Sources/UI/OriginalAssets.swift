import SwiftUI
import UIKit

/// Data-only catalogs copied byte-for-byte from the supplied Goodnotes.app.
enum OriginalAssets {
    static let toolbar = bundle("GN6DesignSystemIcons_GN6ToolbarIcons")
    static let icons = bundle("GN6DesignSystemIcons_GN6DesignSystemIcons")
    static let library = bundle("GNLibraryUI_GNLibraryUIAssets")
    static let colors = bundle("GN6DesignSystemColor_GN6DesignSystemColor")
    static let newDocument = bundle("GNLibraryUI_GNNewDocumentPopover")

    private static func bundle(_ name: String) -> Bundle? {
        guard let root = Bundle.main.resourceURL else { return nil }
        return Bundle(url: root.appendingPathComponent("OriginalAssets/\(name).bundle"))
    }
    static func image(_ name: String, in bundle: Bundle?) -> UIImage? {
        guard let bundle else { return nil }
        return UIImage(named: name, in: bundle, compatibleWith: UITraitCollection(userInterfaceStyle: .dark))
    }
    static func color(_ name: String, fallback: String) -> Color {
        guard let colors, let value = UIColor(named: name, in: colors, compatibleWith: UITraitCollection(userInterfaceStyle: .dark)) else { return Color(hex: fallback) }
        return Color(uiColor: value)
    }
}

struct OriginalIcon: View {
    let name: String
    var catalog: Bundle? = OriginalAssets.toolbar
    var size: CGFloat = 24
    var original = false
    var body: some View {
        Group {
            if let image = OriginalAssets.image(name, in: catalog) {
                Image(uiImage: image).renderingMode(original ? .original : .template).resizable().scaledToFit()
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Point measurements at 1180 × 820, verified against the supplied iPad captures.
enum ReferenceLayout {
    static let tabs: CGFloat = 36
    static let home: CGFloat = 68
    static let tabMax: CGFloat = 552
    static let toolbar: CGFloat = 44
    static let button: CGFloat = 44
    static let toolPitch: CGFloat = 50
    static let selected: CGFloat = 36
    static let floatingHeight: CGFloat = 45
    static let floatingGap: CGFloat = 8
    static let undoWidth: CGFloat = 89
    static let penWidth: CGFloat = 620
    static let popoverWidth: CGFloat = 320
    static let sidebar: CGFloat = 320
    static let pageSidebar: CGFloat = 375
    static let folderPalette = [
        "#8E2E27", "#904424", "#8A5E1D", "#316F29", "#3A5AAA", "#69469D", "#8A3B6D", "#5D5C59", "#1D1B1B",
        "#EC6A6B", "#F1A35A", "#F0CC4A", "#84DA69", "#8EBFFA", "#C7A5F4", "#ED91C4", "#BDBBB5", "#FFFFFF",
        "#F3B1B3", "#F7D0A3", "#F7E887", "#BCF39F", "#D1E4FC", "#E8D8FC", "#F5CEE7", "#E4E2DC"
    ].map { "display-p3:" + $0 }
}
