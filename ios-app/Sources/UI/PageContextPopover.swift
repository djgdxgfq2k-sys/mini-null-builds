import SwiftUI

enum PageMenuAction: String, CaseIterable {
    case before, after, copy, duplicate, rotate, move, outline, export, window, clear, trash
    var title: String {
        switch self {
        case .before: return "Seite oberhalb einfügen"
        case .after: return "Seite unterhalb einfügen"
        case .copy: return "Kopieren"
        case .duplicate: return "Duplizieren"
        case .rotate: return "Drehen"
        case .move: return "Bewegen in …"
        case .outline: return "Seite zur Gliederung hinzufügen"
        case .export: return "Exportieren"
        case .window: return "In neuem Fenster öffnen"
        case .clear: return "Seite leeren"
        case .trash: return "In den Papierkorb"
        }
    }
    var asset: String {
        switch self {
        case .before: return "thumbnails/add-page-before"
        case .after: return "thumbnails/add-page-after"
        case .copy: return "thumbnails/copy"
        case .duplicate: return "thumbnails/duplicate"
        case .rotate: return "thumbnails/rotate"
        case .move: return "thumbnails/move"
        case .outline: return "thumbnails/document-outline"
        case .export: return "thumbnails/export"
        case .window: return "documentActionPopover/open-in-new-window"
        case .clear: return "files/file-x-03"
        case .trash: return "thumbnails/trash"
        }
    }
    var destructive: Bool { self == .clear || self == .trash }
    var catalog: Bundle? { self == .clear || self == .window ? OriginalAssets.icons : OriginalAssets.toolbar }
}

struct PageContextPopover: View {
    let action: (PageMenuAction) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(PageMenuAction.allCases, id: \.self) { item in
                Button { action(item) } label: {
                    HStack(spacing: 12) {
                        OriginalIcon(name: item.asset, catalog: item.catalog, size: 24)
                        Text(item.title).font(.system(size: 15)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 14).frame(height: item == .outline ? 66 : 52).contentShape(Rectangle())
                }.foregroundStyle(item.destructive ? Color(hex: Theme.inks[0]) : .white).disabled(item == .window).opacity(item == .window ? 0.4 : 1).accessibilityHint(item == .copy ? "Seite als PDF kopieren" : "")
                if item != .copy && item != .trash { Divider().overlay(Theme.border.opacity(0.45)).padding(.leading, 52).padding(.trailing, 16) }
            }
        }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 28)).padding(17).frame(width: 278)
            .background(Theme.popover).presentationBackground(Theme.popover).presentationCompactAdaptation(.popover).buttonStyle(.solidPlain)
    }
}
