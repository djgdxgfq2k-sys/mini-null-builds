import SwiftUI
import PencilKit

/// One continuous zooming surface; every page keeps its own authoritative coordinator.
@MainActor struct NotebookCanvas: UIViewRepresentable {
    let pages: [NotebookPage]
    let directory: URL
    let settings: ToolSettings
    let commands: CanvasCommands
    @Binding var pageIndex: Int

    func makeUIView(context: Context) -> NotebookViewport {
        let view = NotebookViewport(directory: directory, commands: commands)
        view.onVisiblePage = { [weak view] index in DispatchQueue.main.async { guard view?.visiblePageIndex == index else { return }; if pageIndex != index { pageIndex = index } } }
        view.synchronize(pages: pages, settings: settings, selected: pageIndex)
        return view
    }
    func updateUIView(_ view: NotebookViewport, context: Context) {
        view.synchronize(pages: pages, settings: settings, selected: pageIndex)
    }
    static func dismantleUIView(_ view: NotebookViewport, coordinator: ()) { view.flush() }
}

@MainActor final class NotebookViewport: UIView, UIScrollViewDelegate {
    private struct Entry {
        var page: NotebookPage
        let viewport: PageViewport
        let coordinator: CanvasSurface.Coordinator
    }
    let scroll = UIScrollView()
    private let stack = UIView()
    private var entries: [String: Entry] = [:]
    private var placeholders: [String: UIView] = [:]
    private var pageFrames: [String: CGRect] = [:]
    private var currentSettings = ToolSettings()
    private var pages: [NotebookPage] = []
    private let directory: URL
    private let commands: CanvasCommands
    private var selectedID: String?
    private var lastSize = CGSize.zero
    private var fitted = false
    private var changingLayout = false
    var onVisiblePage: ((Int) -> Void)?

    init(directory: URL, commands: CanvasCommands) {
        self.directory = directory; self.commands = commands
        super.init(frame: .zero)
        backgroundColor = UIColor(hex: "#1B1C1C")
        addSubview(scroll); scroll.addSubview(stack)
        scroll.delegate = self; scroll.minimumZoomScale = 0.1; scroll.maximumZoomScale = 4
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        scroll.alwaysBounceVertical = true; scroll.showsHorizontalScrollIndicator = false
    }
    required init?(coder: NSCoder) { nil }

    func synchronize(pages: [NotebookPage], settings: ToolSettings, selected: Int) {
        changingLayout = true
        defer { changingLayout = false }
        currentSettings = settings
        let ids = Set(pages.map(\.id))
        for id in Array(entries.keys) where !ids.contains(id) {
            if let entry = entries.removeValue(forKey: id) { entry.coordinator.persist(); entry.viewport.canvas.delegate = nil; entry.viewport.content.removeFromSuperview() }
        }
        for id in Array(placeholders.keys) where !ids.contains(id) { placeholders.removeValue(forKey: id)?.removeFromSuperview() }
        let layoutChanged = self.pages.count != pages.count || zip(self.pages, pages).contains { before, after in before.id != after.id || before.size != after.size }
        self.pages = pages
        for page in pages {
            if placeholders[page.id] == nil {
                let placeholder = UIView(); placeholder.isUserInteractionEnabled = false
                stack.insertSubview(placeholder, at: 0); placeholders[page.id] = placeholder
            }
            placeholders[page.id]?.backgroundColor = UIColor(hex: page.paperColor ?? "#FFFFFF")
            if var entry = entries[page.id], entry.page != page {
                entry.page = page; entries[page.id] = entry
                entry.viewport.updatePage(page)
            }
        }
        scroll.panGestureRecognizer.minimumNumberOfTouches = settings.readOnly || (settings.pencilConnected && !settings.finger) ? 1 : 2
        if layoutChanged { layoutPages() }
        let index = min(max(selected, 0), max(0, pages.count - 1))
        let requestedID = pages.indices.contains(index) ? pages[index].id : nil
        let jump = requestedID != selectedID
        ensureEntries(around: index, includeVisible: !jump)
        if let requestedID {
            select(requestedID, notify: false)
            if (jump || layoutChanged) && fitted { scrollToPage(requestedID) }
        }
        for entry in entries.values { entry.coordinator.configure(settings) }
        if let selectedID { commands.target = entries[selectedID]?.coordinator }
    }

    private func ensureEntries(around index: Int, includeVisible: Bool) {
        guard !pages.isEmpty else { return }
        var lower = max(0, index - 2), upper = min(pages.count - 1, index + 2)
        if includeVisible && fitted {
            let visible = stack.convert(scroll.bounds, from: scroll)
            let indices = pages.indices.filter { pageFrames[pages[$0].id]?.intersects(visible) == true }
            if let first = indices.first, let last = indices.last { lower = max(0, first - 1); upper = min(pages.count - 1, last + 1) }
        }
        if upper - lower + 1 > 16 { lower = max(lower, index - 8); upper = min(upper, lower + 15) }
        let wanted = Set(pages[lower...upper].map(\.id))
        for id in Array(entries.keys) where !wanted.contains(id) {
            guard let entry = entries[id], !entry.coordinator.usingTool else { continue }
            // Failed saves retain the live coordinator and its authoritative drawing.
            guard entry.coordinator.persist() else { continue }
            entry.viewport.canvas.delegate = nil; entry.viewport.content.removeFromSuperview(); entries.removeValue(forKey: id)
        }
        for page in pages[lower...upper] where entries[page.id] == nil {
            let viewport = PageViewport(page: page, directory: directory)
            let coordinator = CanvasSurface.Coordinator(page: page, directory: directory, commands: commands)
            coordinator.attach(viewport)
            coordinator.onActivate = { [weak self] in self?.select(page.id, notify: true) }
            stack.addSubview(viewport.content)
            viewport.content.frame = pageFrames[page.id] ?? CGRect(origin: .zero, size: page.size)
            coordinator.configure(currentSettings)
            entries[page.id] = Entry(page: page, viewport: viewport, coordinator: coordinator)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews(); scroll.frame = bounds
        guard bounds.width > 0, bounds.height > 0, bounds.size != lastSize, let first = pages.first else { return }
        lastSize = bounds.size
        changingLayout = true
        scroll.zoomScale = max(0.1, min(4, min((bounds.width - 48) / first.size.width, (bounds.height - 80) / first.size.height)))
        fitted = true; centerHorizontally()
        if let selectedID { scrollToPage(selectedID) }
        changingLayout = false
        updateVisiblePage()
    }
    private func layoutPages() {
        let width = pages.map { $0.size.width }.max() ?? 0
        var y: CGFloat = 0
        pageFrames = [:]
        for page in pages {
            let frame = CGRect(x: (width - page.size.width) / 2, y: y, width: page.size.width, height: page.size.height)
            pageFrames[page.id] = frame
            placeholders[page.id]?.frame = frame
            entries[page.id]?.viewport.content.frame = frame
            y += page.size.height + 20
        }
        let scale = scroll.zoomScale
        stack.bounds = CGRect(x: 0, y: 0, width: width, height: max(0, y - 20))
        stack.frame = CGRect(origin: .zero, size: CGSize(width: width * scale, height: max(0, y - 20) * scale))
        scroll.contentSize = stack.frame.size
        centerHorizontally()
    }
    private func centerHorizontally() {
        let side = max(24, (bounds.width - scroll.contentSize.width) / 2)
        scroll.contentInset = UIEdgeInsets(top: 60, left: side, bottom: 20, right: side)
    }
    private func scrollToPage(_ id: String) {
        guard let frame = pageFrames[id] else { return }
        scroll.setContentOffset(CGPoint(x: -scroll.contentInset.left, y: frame.minY * scroll.zoomScale - scroll.contentInset.top), animated: false)
    }
    private func select(_ id: String, notify: Bool) {
        selectedID = id; commands.target = entries[id]?.coordinator
        if notify, let index = pages.firstIndex(where: { $0.id == id }) { onVisiblePage?(index) }
    }
    private func updateVisiblePage() {
        guard !changingLayout, fitted else { return }
        let visible = stack.convert(scroll.bounds, from: scroll)
        let best = pages.max { lhs, rhs in
            let a = pageFrames[lhs.id]?.intersection(visible).height ?? 0
            let b = pageFrames[rhs.id]?.intersection(visible).height ?? 0
            return a < b
        }
        if let best, let index = pages.firstIndex(where: { $0.id == best.id }) {
            changingLayout = true
            ensureEntries(around: index, includeVisible: true)
            let changed = best.id != selectedID
            select(best.id, notify: changed)
            changingLayout = false
        }
    }
    var livePageCount: Int { entries.count }
    var visiblePageIndex: Int? { pages.firstIndex(where: { $0.id == selectedID }) }
    func coordinator(for pageID: String) -> CanvasSurface.Coordinator? { entries[pageID]?.coordinator }
    func flush() { for entry in entries.values { entry.viewport.inkInput.finishPendingStroke(); entry.coordinator.persist() } }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { stack }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerHorizontally(); updateVisiblePage() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisiblePage() }
}
