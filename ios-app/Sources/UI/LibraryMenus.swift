import SwiftUI

enum LibraryMenuKind: Hashable { case filter, layout }

struct LibraryMenuAnchorKey: PreferenceKey {
    static var defaultValue: [LibraryMenuKind: Anchor<CGRect>] = [:]
    static func reduce(value: inout [LibraryMenuKind: Anchor<CGRect>], nextValue: () -> [LibraryMenuKind: Anchor<CGRect>]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

enum LibrarySort: String, CaseIterable {
    case created = "Erstellungsdatum", modified = "Letzte Änderung", title = "Titel", kind = "Art"
    func ordered(_ items: [LibraryItem], ascending: Bool) -> [LibraryItem] {
        items.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch self {
            case .created: comparison = (lhs.created ?? lhs.modified).compare(rhs.created ?? rhs.modified)
            case .modified: comparison = lhs.modified.compare(rhs.modified)
            case .title: comparison = lhs.title.localizedStandardCompare(rhs.title)
            case .kind:
                func rank(_ item: LibraryItem) -> Int { item.folder ? 0 : (item.kind == .whiteboard ? 2 : 1) }
                comparison = rank(lhs) == rank(rhs) ? .orderedSame : (rank(lhs) < rank(rhs) ? .orderedAscending : .orderedDescending)
            }
            if comparison == .orderedSame {
                let title = lhs.title.localizedStandardCompare(rhs.title)
                return title == .orderedSame ? lhs.id < rhs.id : title == .orderedAscending
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
}

struct LibraryFilterMenu: View {
    let selected: String
    let select: (String) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(["Alle", "Dokumente", "Ordner"], id: \.self) { value in
                Button { select(value) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)).frame(width: 10).opacity(value == selected ? 1 : 0)
                        Text(value); Spacer(minLength: 0)
                    }.padding(.horizontal, 16).frame(height: 34).contentShape(Rectangle())
                }.accessibilityAddTraits(value == selected ? .isSelected : [])
            }
        }.padding(.vertical, 8).libraryMenuSurface()
    }
}

struct LibraryLayoutMenu: View {
    let listLayout: Bool
    let sort: LibrarySort
    let ascending: Bool
    let selectObjects: () -> Void
    let setLayout: (Bool) -> Void
    let setSort: (LibrarySort) -> Void
    var body: some View {
        VStack(spacing: 0) {
            row("Objekte auswählen", symbol: "checkmark.circle", action: selectObjects)
            separator
            row("Raster", symbol: "square.grid.2x2", selected: !listLayout) { setLayout(false) }
            row("Liste", symbol: "list.bullet", selected: listLayout) { setLayout(true) }
            separator
            ForEach(LibrarySort.allCases, id: \.self) { criterion in
                row(criterion.rawValue, symbol: sort == criterion ? (ascending ? "chevron.up" : "chevron.down") : nil, selected: sort == criterion) { setSort(criterion) }
            }
        }.padding(.vertical, 8).libraryMenuSurface()
    }
    private var separator: some View { Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5).padding(.horizontal, 20).frame(height: 17) }
    private func row(_ title: String, symbol: String?, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)).frame(width: 10).opacity(selected ? 1 : 0).padding(.trailing, 7)
                Group { if let symbol { Image(systemName: symbol).font(.system(size: title == "Objekte auswählen" ? 18 : (symbol.hasPrefix("chevron") ? 12 : 15))) } else { Color.clear } }.frame(width: 18, height: 20).padding(.trailing, 11)
                Text(title); Spacer(minLength: 0)
            }.padding(.leading, 15).padding(.trailing, 16).frame(height: 34).contentShape(Rectangle())
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension View {
    func libraryMenuSurface() -> some View {
        self.font(.system(size: 13)).foregroundStyle(.white).buttonStyle(.solidPlain).frame(width: 224)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
            .overlay { RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.14), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
    }
}
