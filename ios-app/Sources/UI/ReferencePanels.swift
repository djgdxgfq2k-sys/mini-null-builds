import SwiftUI

struct ReferenceToolMenu: View {
    let title: String
    let entries: [(String, String)]
    var enabled: Set<Int> = [0, 1, 2, 3]
    let action: (Int) -> Void
    var body: some View {
        VStack(spacing: 18) {
            Text(title).font(.system(size: 17, weight: .semibold)).padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(entries.indices, id: \.self) { index in
                    Button { action(index) } label: { HStack(spacing: 12) { OriginalIcon(name: entries[index].1, size: 22); Text(entries[index].0); Spacer() }.font(.system(size: 15)).padding(.horizontal, 14).frame(height: 44.5).contentShape(Rectangle()) }.disabled(!enabled.contains(index)).opacity(enabled.contains(index) ? 1 : 0.4)
                    if index < entries.count - 1 { Divider().overlay(Theme.border).padding(.leading, 48) }
                }
            }.background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
        }.padding(17).frame(width: 320).foregroundStyle(.white).background(Theme.popover).presentationBackground(Theme.popover).presentationCompactAdaptation(.popover)
    }
}
