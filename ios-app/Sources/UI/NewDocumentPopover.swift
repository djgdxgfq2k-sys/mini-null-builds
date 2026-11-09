import SwiftUI

struct NewDocumentPopover: View {
    let notebook: () -> Void
    let whiteboard: () -> Void
    let importFile: () -> Void
    let quickNote: () -> Void
    let scan: () -> Void
    let image: () -> Void
    let camera: () -> Void
    let folder: () -> Void
    var textDocument: () -> Void = {}
    var quickRecording: () -> Void = {}
    var flashcards: () -> Void = {}
    var canScan = true
    var canUseCamera = true

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                tile("Notizbuch", asset: "notebook", action: notebook)
                tile("Whiteboard", asset: "canvas", badge: true, action: whiteboard)
                tile("Text-Dok", asset: "nexus", badge: true, action: textDocument)
            }
            HStack(spacing: 8) {
                tile("Importieren", asset: "import", action: importFile)
                tile("Schnellaufnahme", asset: "add-recording", action: quickRecording)
            }
            VStack(spacing: 0) {
                row("QuickNote", asset: "newDocumentPopover/quicknote", action: quickNote)
                row("Dokumente scannen", asset: "newDocumentPopover/scan-document", catalog: OriginalAssets.toolbar, action: scan).disabled(!canScan)
                row("Lernset", asset: "newDocumentPopover/flashcards", action: flashcards)
                row("Bild", asset: "newDocumentPopover/image", action: image)
                row("Foto aufnehmen", asset: "newDocumentPopover/take-photo", action: camera).disabled(!canUseCamera)
            }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
            row("Ordner", asset: "newDocumentPopover/folder", action: folder).background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
        }.padding(12).frame(width: 320).foregroundStyle(.white).background(Theme.popover).presentationBackground(Theme.popover).presentationCompactAdaptation(.popover).buttonStyle(.solidPlain)
    }
    private func tile(_ title: String, asset: String, badge: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) { OriginalIcon(name: "newDocumentPopover/" + asset, catalog: OriginalAssets.icons, size: 24); Text(title).font(.system(size: 11)) }.frame(maxWidth: .infinity).frame(height: 74).background(Theme.pill, in: RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topTrailing) { if badge { Text("NEU").font(.system(size: 7, weight: .semibold)).foregroundStyle(Color(hex: "#D3D987")).padding(4).background(Color(hex: "#383F13"), in: Capsule()).offset(x: 2, y: -6) } }
        }
    }
    private func row(_ title: String, asset: String, catalog: Bundle? = OriginalAssets.icons, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 12) { OriginalIcon(name: asset, catalog: catalog, size: 20); Text(title).font(.system(size: 15)); Spacer() }.padding(.horizontal, 14).frame(height: 44.5).contentShape(Rectangle()) }
    }
}
