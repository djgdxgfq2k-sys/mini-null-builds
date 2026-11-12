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
    private var orderedFrames: [CGRect] = []
    private var retainedRange: ClosedRange<Int>?
    private var currentSettings = ToolSettings()
    private var pages: [NotebookPage] = []
    private let directory: URL
    private let commands: CanvasCommands
    private var selectedID: String?
    private var lastSize = CGSize.zero
    private var fitted = false
    private var changingLayout = false
    private var backgroundObserver: NSObjectProtocol?
    var onVisiblePage: ((Int) -> Void)?

    init(directory: URL, commands: CanvasCommands) {
        self.directory = directory; self.commands = commands
        super.init(frame: .zero)
        backgroundColor = UIColor(hex: "#1B1C1C")
        addSubview(scroll); scroll.addSubview(stack)
        scroll.delegate = self; scroll.minimumZoomScale = 0.1; scroll.maximumZoomScale = PageViewport.maximumZoom
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        scroll.alwaysBounceVertical = true; scroll.showsHorizontalScrollIndicator = false
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.flush() }
        }
    }
    deinit { if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) } }
    required init?(coder: NSCoder) { nil }

    func synchronize(pages: [NotebookPage], settings: ToolSettings, selected: Int) {
        guard pages != self.pages || settings != currentSettings || visiblePageIndex != selected else { return }
        changingLayout = true
        defer { changingLayout = false }
        currentSettings = settings
        let ids = Set(pages.map(\.id))
        for id in Array(entries.keys) where !ids.contains(id) {
            if let entry = entries.removeValue(forKey: id) { entry.viewport.endEditing(true); entry.coordinator.persist(force: false); entry.viewport.canvas.delegate = nil; entry.viewport.content.removeFromSuperview() }
        }
        for id in Array(placeholders.keys) where !ids.contains(id) { placeholders.removeValue(forKey: id)?.removeFromSuperview() }
        let layoutChanged = self.pages.count != pages.count || zip(self.pages, pages).contains { before, after in before.id != after.id || before.size != after.size }
        if self.pages.map(\.id) != pages.map(\.id) { retainedRange = nil }
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
        // Hand tool: the Pencil moves the page like a finger and never writes.
        let hand = settings.tool == .hand
        scroll.panGestureRecognizer.minimumNumberOfTouches = hand || settings.readOnly || (settings.pencilConnected && !settings.finger) ? 1 : 2
        scroll.panGestureRecognizer.allowedTouchTypes = ((hand || settings.readOnly) ? [UITouch.TouchType.direct, .indirectPointer, .pencil] : [UITouch.TouchType.direct, .indirectPointer]).map { NSNumber(value: $0.rawValue) }
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
        // Pages are built a few pages ahead so scrolling never shows a page being drawn in.
        var lower = max(0, index - 3), upper = min(pages.count - 1, index + 3)
        if includeVisible && fitted {
            let visible = stack.convert(scroll.bounds, from: scroll)
            let indices = visibleIndices(in: visible)
            if let first = indices.first, let last = indices.last { lower = max(0, first - 2); upper = min(pages.count - 1, last + 2) }
        }
        if upper - lower + 1 > 16 { lower = max(lower, index - 8); upper = min(upper, lower + 15) }
        let range = lower...upper
        guard retainedRange != range else { return }
        retainedRange = range
        let wanted = Set(pages[lower...upper].map(\.id))
        for id in Array(entries.keys) where !wanted.contains(id) {
            guard let entry = entries[id] else { continue }
            guard !entry.coordinator.usingTool else { retainedRange = nil; continue }
            // Failed saves retain the live coordinator and its authoritative drawing.
            entry.viewport.endEditing(true)
            guard entry.coordinator.persist(force: false) else { retainedRange = nil; continue }
            entry.viewport.canvas.delegate = nil; entry.viewport.content.removeFromSuperview(); entries.removeValue(forKey: id)
        }
        for page in pages[lower...upper] where entries[page.id] == nil {
            let (viewport, coordinator) = HangMonitor.measure("build page") { () -> (PageViewport, CanvasSurface.Coordinator) in
                let viewport = PageViewport(page: page, directory: directory)
                let coordinator = CanvasSurface.Coordinator(page: page, directory: directory, commands: commands)
                coordinator.attach(viewport)
                return (viewport, coordinator)
            }
            coordinator.onActivate = { [weak self] in self?.select(page.id, notify: true) }
            stack.addSubview(viewport.content)
            viewport.content.frame = pageFrames[page.id] ?? CGRect(origin: .zero, size: page.size)
            let visible = stack.convert(scroll.bounds, from: scroll)
            viewport.outerZoom = pageFrames[page.id]?.intersects(visible) == true ? scroll.zoomScale : 1
            coordinator.configure(currentSettings)
            entries[page.id] = Entry(page: page, viewport: viewport, coordinator: coordinator)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews(); scroll.frame = bounds
        guard bounds.width > 0, bounds.height > 0, bounds.size != lastSize, let first = pages.first else { return }
        lastSize = bounds.size
        changingLayout = true
        let initiallyFitted = fitted
        if !fitted { scroll.zoomScale = max(0.1, min(4, min((bounds.width - 48) / first.size.width, (bounds.height - 80) / first.size.height))) }
        fitted = true; centerHorizontally(); applyRenderZoom()
        if !initiallyFitted, let selectedID { scrollToPage(selectedID) }
        changingLayout = false
        updateVisiblePage()
    }
    private func layoutPages() {
        let width = pages.map { $0.size.width }.max() ?? 0
        var y: CGFloat = 0
        pageFrames = [:]; orderedFrames = []
        for page in pages {
            let frame = CGRect(x: (width - page.size.width) / 2, y: y, width: page.size.width, height: page.size.height)
            pageFrames[page.id] = frame
            orderedFrames.append(frame)
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
        let inset = UIEdgeInsets(top: 60, left: side, bottom: 20, right: side)
        if scroll.contentInset != inset { scroll.contentInset = inset }
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
        let indices = visibleIndices(in: visible)
        if let index = indices.max(by: { orderedFrames[$0].intersection(visible).height < orderedFrames[$1].intersection(visible).height }) {
            let best = pages[index]
            changingLayout = true
            ensureEntries(around: index, includeVisible: true)
            let changed = best.id != selectedID
            select(best.id, notify: changed)
            changingLayout = false
            if !scroll.isZooming { applyRenderZoom() }
        }
    }
    /// Frames are sorted vertically. Scrolling touches only the visible range, even in
    /// notebooks with thousands of pages, rather than scanning every page each frame.
    private func visibleIndices(in rect: CGRect) -> Range<Int> {
        var low = 0, high = orderedFrames.count
        while low < high {
            let middle = (low + high) / 2
            if orderedFrames[middle].maxY < rect.minY { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < orderedFrames.count, orderedFrames[end].minY <= rect.maxY { end += 1 }
        return low..<end
    }
    var livePageCount: Int { entries.count }
    var visiblePageIndex: Int? { pages.firstIndex(where: { $0.id == selectedID }) }
    func coordinator(for pageID: String) -> CanvasSurface.Coordinator? { entries[pageID]?.coordinator }
    func flush() { for entry in entries.values { entry.viewport.endEditing(true); entry.viewport.inkInput.finishPendingStroke(); entry.coordinator.persist(force: false) } }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { stack }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerHorizontally(); updateVisiblePage() }
    /// After a pinch, visible pages re-render at the new zoom; neighbors stay inexpensive.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { applyRenderZoom() }
    private func applyRenderZoom() {
        let visible = stack.convert(scroll.bounds, from: scroll)
        for entry in entries.values where !entry.coordinator.usingTool {
            // Prefetched pages keep their ink at base resolution. Allocating an 8192px
            // PencilKit surface for every offscreen neighbor wastes hundreds of MB at deep zoom.
            entry.viewport.outerZoom = pageFrames[entry.page.id]?.intersects(visible) == true ? scroll.zoomScale : 1
        }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { HangMonitor.shared.lastScroll = CACurrentMediaTime(); updateVisiblePage() }
}
