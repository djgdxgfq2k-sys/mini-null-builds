import SwiftUI

private struct GoodnotesSheetStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background(Theme.popover)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(Theme.accent).preferredColorScheme(.dark)
    }
}
extension View {
    func goodnotesSheet() -> some View { modifier(GoodnotesSheetStyle()) }
    func goodnotesPill() -> some View {
        background(Theme.pill, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
    }
}

struct FolderArtwork: View {
    let color: String
    var symbol: String? = nil
    var body: some View {
        ZStack {
            if let catalog = OriginalAssets.library {
                Image("custom-folder/back_shadow", bundle: catalog).resizable().scaledToFit()
                Image("custom-folder/back_cover", bundle: catalog).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Color(hex: color).opacity(0.85))
                Image("custom-folder/front_cover", bundle: catalog).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Color(hex: color))
                Image("custom-folder/front_highlight", bundle: catalog).resizable().scaledToFit()
                Image("custom-folder/front_shadow", bundle: catalog).resizable().scaledToFit()
            }
            if let symbol {
                if symbol.hasPrefix("folder-symbols/") { OriginalIcon(name: symbol, catalog: OriginalAssets.library, size: 30).foregroundStyle(.white.opacity(0.8)).offset(y: 8) }
                else { Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.8)).offset(y: 8) }
            }
        }.shadow(color: .black.opacity(0.28), radius: 7, y: 6)
    }
}
struct FolderShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + 9))
        p.addQuadCurve(to: CGPoint(x: r.minX + 9, y: r.minY), control: r.origin)
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.30, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + r.width * 0.49, y: r.minY + 12), control1: CGPoint(x: r.minX + r.width * 0.39, y: r.minY), control2: CGPoint(x: r.minX + r.width * 0.39, y: r.minY + 12))
        p.addLine(to: CGPoint(x: r.maxX - 10, y: r.minY + 12))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + 22), control: CGPoint(x: r.maxX, y: r.minY + 12))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 10))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 10, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 10, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 10), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath(); return p
    }
}
