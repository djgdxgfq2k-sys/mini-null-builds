import XCTest
import SwiftUI
import UIKit
import PencilKit
import PDFKit
@testable import NullMini

@MainActor final class VisualReferenceTests: XCTestCase {
    func testOriginalAppCatalogsLoadOnIPad() throws {
        try XCTSkipIf(OriginalAssets.toolbar == nil, "Original Goodnotes assets are kept on the local PC only")
        for name in ["navbar/home", "navbar/sidebar", "navbar/search", "navbar/addPage", "navbar/share", "navbar/more-circle", "newToolbar/lasso/lasso", "newToolbar/writing_tools/writing_tools", "newToolbar/writing_tools/writing_tools_selected", "newToolbar/writing_tools/tools/ball_pen", "newToolbar/eraser/eraser_stroke", "newToolbar/element", "newToolbar/laser_pointer", "newToolbar/accessories", "toolbar/tool_undo", "toolbar/tool_redo"] {
            let image = try XCTUnwrap(OriginalAssets.image(name, in: OriginalAssets.toolbar), "Original asset missing: \(name)")
            XCTAssertGreaterThan(image.size.width, 0)
        }
        for name in ["custom-folder/back_cover", "custom-folder/front_cover", "custom-folder/front_highlight", "custom-folder/front_shadow", "folder-symbols/folder_icon_atom"] {
            XCTAssertNotNil(OriginalAssets.image(name, in: OriginalAssets.library), "Original folder asset missing: \(name)")
        }
        for shape in GeometricShape.allCases { XCTAssertNotNil(OriginalAssets.image(shape.asset, in: OriginalAssets.toolbar), "Original shape asset missing: \(shape.asset)") }
        for action in PageMenuAction.allCases { XCTAssertNotNil(OriginalAssets.image(action.asset, in: action.catalog), "Original page action asset missing: \(action.asset)") }
        for name in ["segmentedControl/file-04", "segmentedControl/document-outline", "segmentedControl/Transcripts", "general/bookmark"] { XCTAssertNotNil(OriginalAssets.image(name, in: OriginalAssets.icons), "Original sidebar asset missing: \(name)") }
        for name in ["files/file-06", "images/image-01", "images/camera-01", "general/download-01", "arrows/arrow-square-right"] { XCTAssertNotNil(OriginalAssets.image(name, in: OriginalAssets.icons), "Original document action asset missing: \(name)") }
        XCTAssertNotNil(OriginalAssets.image("newDocumentPopover/scan-document", in: OriginalAssets.toolbar))
        for name in ["toolbar/tool_ballpen_selected_alternate", "toolbar/tool_fountainpen_selected_alternate", "toolbar/tool_brushpen_selected_alternate", "toolbar/tool_eraser_selected_alternate", "toolbar/tool_segment_eraser_selected_alternate", "toolbar/tool_object_eraser_selected_alternate", "toolbar/tool_hb_pencil"] { XCTAssertNotNil(OriginalAssets.image(name, in: OriginalAssets.icons), name) }
        for name in ["newToolbar/lasso/lasso_mode_rectangular_selected", "newToolbar/lasso/lasso_mode_freehand_selected", "newToolbar/writing_tools/tools/pencil", "newToolbar/writing_tools/tools/tape"] { XCTAssertNotNil(OriginalAssets.image(name, in: OriginalAssets.toolbar), name) }
        for name in ["newToolbar/toggles-all", "newToolbar/toggles-some", "newToolbar/eraser_size/eraser_small_selected", "newToolbar/eraser_size/eraser_medium", "newToolbar/eraser_size/eraser_large"] { XCTAssertNotNil(OriginalAssets.image(name, in: OriginalAssets.toolbar), name) }
    }

    func testReferenceScreenCaptures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let book = try XCTUnwrap(store.items.first(where: { !$0.folder }))
        await capture("library-1180x820", view: LibraryView().environmentObject(store), size: CGSize(width: 1180, height: 820), topInset: 34)
        store.open(book.id)
        await capture("editor-1180x820", view: EditorView(bookID: book.id).environmentObject(store), size: CGSize(width: 1180, height: 820), topInset: 34)
        await capture("editor-portrait", view: EditorView(bookID: book.id).environmentObject(store), size: CGSize(width: 820, height: 1180), topInset: 34)
        await capture("folder-creation", view: FolderCreationView { _, _, _ in }, size: CGSize(width: 1180, height: 820), topInset: 34)
        await capture("folder-over-library", view: LibraryView(showFolderCreation: true).environmentObject(store), size: CGSize(width: 1180, height: 820), topInset: 34)
        let school = try XCTUnwrap(store.add(title: "Schule", folder: true))
        for item in store.items where item.id != school.id { store.move(item.id, into: school.id) }
        await capture("library-filter", view: LibraryView(sidebarShown: false, menu: .filter, folderID: school.id).environmentObject(store), size: CGSize(width: 1180, height: 820), topInset: 34)
        await capture("library-layout", view: LibraryView(sidebarShown: false, menu: .layout, folderID: school.id).environmentObject(store), size: CGSize(width: 1180, height: 820), topInset: 34)
        await capture("new-notebook", view: NotebookCreationView { _, _, _, _ in }, size: CGSize(width: 712, height: 726))
        await capture("new-whiteboard", view: WhiteboardCreationView { _, _, _, _ in }, size: CGSize(width: 712, height: 726))
        await capture("ink-swatches", view: HStack(spacing: 24) { ForEach(Theme.inks, id: \.self) { color in Circle().fill(Color(hex: color)).frame(width: 20, height: 20) } }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.pill), size: CGSize(width: 264, height: 45))
        await capture("ink-palette", view: InkColorPalette(settings: .constant(ToolSettings())), size: CGSize(width: 410, height: 336))
        var shapes = ToolSettings(); shapes.tool = .geometry; shapes.color = "#FFFFFF"; shapes.fillShapes = true
        await capture("shape-toolbar", view: ShapeContextToolbar(settings: .constant(shapes)).goodnotesPill(), size: CGSize(width: 459, height: 45))
        await capture("shape-color", view: InkColorPalette(settings: .constant(shapes)), size: CGSize(width: 410, height: 479))
        await capture("stroke-settings", view: StrokeOptionsPopover(settings: .constant(shapes)), size: CGSize(width: 320, height: 289))
        await capture("new-document-menu", view: NewDocumentPopover(notebook: {}, whiteboard: {}, importFile: {}, quickNote: {}, scan: {}, image: {}, camera: {}, folder: {}), size: CGSize(width: 320, height: 500))
        for tool in [EditorTool.pen, .eraser, .marker, .lasso, .shapes, .laser] {
            var state = ToolSettings(); state.tool = tool
            if tool == .marker { state.straightHighlighter = true }
            if tool == .lasso { state.rectangularLasso = true }
            if tool == .shapes { state.roundedShapes = true; state.fillShapes = true }
            await capture("tool-\(tool.rawValue)", view: ToolOptionsView(tool: tool, settings: .constant(state)), size: ToolOptionsView.panelSize(for: tool))
        }
        await capture("tool-pen-scrolled", view: ToolOptionsView(tool: .pen, settings: .constant(ToolSettings()), initiallyScrolled: true), size: ToolOptionsView.panelSize(for: .pen))
        await capture("eraser-toolbar", view: EraserContextToolbar(settings: .constant(ToolSettings()), selectType: {}, clearPage: {}).goodnotesPill(), size: CGSize(width: 362, height: 45))
        await capture("eraser-advanced", view: EraserAdvancedOptions(settings: .constant(ToolSettings()), clearPage: {}), size: CGSize(width: 393, height: 588))
        await capture("writing-tools", view: WritingToolMenu(pencil: {}, customize: {}), size: CGSize(width: 320, height: 232))
        await capture("page-sidebar", view: DocumentSidebar(item: book, directory: store.directory(book.id), mode: .pages, pageIndex: .constant(0), close: {}, addPage: {}, flush: {}), size: CGSize(width: 375, height: 706))
        await capture("page-context-menu", view: PageContextPopover { _ in }, size: CGSize(width: 278, height: 625))
        await capture("add-page", view: PageAddPopover { _, _ in }, size: CGSize(width: 390, height: 650))
        await capture("export", view: ExportPopover(exportPage: {}, exportAll: {}, exportNative: {}, exportOriginal: nil, printDocument: {}), size: CGSize(width: 320, height: 430))
        await capture("document-more", view: DocumentMorePopover(pageNumber: 3, bookmarked: false, bookmark: {}, rename: {}, changeTemplate: { _ in }, readOnly: .constant(false), finger: .constant(true), report: {}, pageCount: 3), size: CGSize(width: 320, height: 665))
    }

    func testThumbnailIncludesSavedDrawingWithoutChangingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var book = try XCTUnwrap(store.add(title: "Thumbnail")); book.pages[0].paper = "blank"
        let drawing = PKDrawing(strokes: [StrokeFactory.stroke(points: [CGPoint(x: 10, y: 10), CGPoint(x: 500, y: 700)], color: .red, width: 12)])
        let directory = store.directory(book.id), page = book.pages[0]
        try DrawingDisk.save(drawing, directory: directory, page: page.id)
        let before = try Data(contentsOf: DrawingDisk.url(directory, page.id))
        let image = try NotebookThumbnail.render(page: page, directory: directory)
        XCTAssertEqual(image.size.width, 160)
        XCTAssertEqual(try Data(contentsOf: DrawingDisk.url(directory, page.id)), before)
        let attachment = XCTAttachment(image: image); attachment.name = "saved-drawing-thumbnail"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testMediaImportKeepsPageCountAndImageOrientation() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 100)) }
        let portrait = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200), format: format).image { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 200)) }
        let pdf = try DocumentMediaPDF.write([landscape, portrait])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pdf); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let item = try NotebookArchive.importFile(pdf, into: store, parent: nil)
        XCTAssertEqual(item.pages.count, 2)
        XCTAssertEqual(item.pages[0].width / item.pages[0].height, 2, accuracy: 0.01)
        XCTAssertEqual(item.pages[1].width / item.pages[1].height, 0.5, accuracy: 0.01)
    }

    func testOriginalWhiteboardBackgroundCanBeCreatedAndReopened() async throws {
        try XCTSkipIf(OriginalAssets.toolbar == nil, "Original Goodnotes assets are kept on the local PC only")
        for (_, templates) in WhiteboardTemplate.sections {
            for template in templates {
                for dark in [false, true] { XCTAssertNotNil(template.image(dark: dark), "Missing original preview: \(template.name)") }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        try await WhiteboardTemplate.create(WhiteboardTemplate(name: "Daily Standup"), dark: false, title: "Team", store: store, parent: nil)
        let reloaded = LibraryStore(root: root)
        let item = try XCTUnwrap(reloaded.items.first { $0.title == "Team" })
        XCTAssertEqual(item.kind, .whiteboard)
        let page = try XCTUnwrap(item.pages.first), name = try XCTUnwrap(page.pdf)
        let pdf = try XCTUnwrap(PDFDocument(url: reloaded.directory(item.id).appendingPathComponent(name)))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(page.width / page.height, 4 / 3, accuracy: 0.01)
        let drawing = PKDrawing(strokes: [StrokeFactory.stroke(points: [.zero, CGPoint(x: 80, y: 90)], color: .blue, width: 2)])
        try DrawingDisk.save(drawing, directory: reloaded.directory(item.id), page: page.id)
        XCTAssertEqual(try DrawingDisk.load(reloaded.directory(item.id), page.id).strokes.count, 1)
    }

    func testCustomPaletteAndRecentColorsSurviveReopening() throws {
        let suite = "nullmini-palette-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let palette = InkPaletteStore(defaults: defaults), color = "display-p3:#84DA69"
        palette.save(color); palette.remember("#123456"); palette.remember(color)
        let reopened = InkPaletteStore(defaults: defaults)
        XCTAssertEqual(reopened.saved, [color]); XCTAssertEqual(reopened.recent, [color, "#123456"])
        XCTAssertEqual(UIColor(hex: color).displayP3Hex, color)
        XCTAssertEqual(UIColor(hex: "#123456").rgbHex, "#123456")
        reopened.remove(color)
        XCTAssertTrue(InkPaletteStore(defaults: defaults).saved.isEmpty)
        XCTAssertEqual(InkPaletteStore(defaults: defaults).recent, [color, "#123456"])
    }

    private func capture<V: View>(_ name: String, view: V, size: CGSize, topInset: CGFloat = 0) async {
        let root = AnyView(view.preferredColorScheme(.dark))
        let host = UIHostingController(rootView: topInset == 0 ? AnyView(root.ignoresSafeArea()) : root)
        host.overrideUserInterfaceStyle = .dark
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        host.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, topInset - host.view.safeAreaInsets.top), left: 0, bottom: 0, right: 0)
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 400_000_000)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let surface = host.presentedViewController?.view ?? host.view!
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in surface.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
        if let cgImage = image.cgImage {
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            var visiblePixels = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let brightness = Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
                if brightness > 90 { visiblePixels += 1 }
            }
            XCTAssertGreaterThan(visiblePixels, 8, "Blank reference capture: \(name)")
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true
    }

    func testOriginalIconAndColorInventory() throws {
        try XCTSkipIf(OriginalAssets.toolbar == nil, "Original Goodnotes assets are kept on the local PC only")
        let groups: [(String, Bundle?, [String])] = [
            ("Toolbar", OriginalAssets.toolbar, ["navbar/home", "navbar/sidebar", "navbar/search", "navbar/pen", "navbar/pen_selected", "navbar/asterisk-01-selected", "navbar/study", "navbar/study_navigator", "navbar/microphone", "navbar/more-circle", "newToolbar/lasso/lasso", "newToolbar/lasso/lasso_rectangular", "newToolbar/selection", "newToolbar/element", "newToolbar/shapes", "newToolbar/writing_tools/writing_tools", "newToolbar/writing_tools/tools/ball_pen", "newToolbar/writing_tools/tools/brush_pen", "newToolbar/writing_tools/tools/fountain_pen", "newToolbar/accessories", "newToolbar/accessories2", "newToolbar/accessories3", "newToolbar/accessories/start_audio_recording"]),
            ("Legacy", OriginalAssets.icons, ["toolbar/tool_ballpen", "toolbar/tool_ballpen_selected", "toolbar/tool_fountainpen", "toolbar/tool_fountainpen_selected", "toolbar/tool_brushpen", "toolbar/tool_highlighter", "toolbar/tool_lasso", "toolbar/tool_shapes", "toolbar/tool_elements", "toolbar/tool_laser", "toolbar/tool_texttool", "toolbar/tool_scan", "general/search-lg"]),
            ("Library", OriginalAssets.library, ["folders/folder_blue", "folders/folder_green", "folders/folder_orange", "custom-folder/front_cover", "folder-palette/rainbow"])
        ]
        let entries = groups.flatMap { label, bundle, names in names.map { (label, bundle, $0) } }
        for (catalog, bundle, name) in entries {
            if let image = OriginalAssets.image(name, in: bundle), let data = image.pngData() {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "original-" + catalog + "--" + name.replacingOccurrences(of: "/", with: "_")
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        var sizes: [String: String] = [:]
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let gallery = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: CGFloat((entries.count + 4) / 5) * 130), format: format).image { context in
            UIColor(hex: "#2A2C2C").setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: CGFloat((entries.count + 4) / 5) * 130))
            for (index, entry) in entries.enumerated() {
                let x = CGFloat(index % 5) * 200, y = CGFloat(index / 5) * 130
                if let image = OriginalAssets.image(entry.2, in: entry.1) {
                    sizes[entry.0 + "/" + entry.2] = "\(image.size.width) x \(image.size.height)"
                    let fit = min(60 / image.size.width, 60 / image.size.height)
                    image.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: x + 70, y: y + 8, width: image.size.width * fit, height: image.size.height * fit))
                }
                ((entry.0 + "/" + entry.2) as NSString).draw(in: CGRect(x: x + 5, y: y + 75, width: 190, height: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.white])
            }
        }
        let imageAttachment = XCTAttachment(image: gallery); imageAttachment.name = "original-icon-inventory"; imageAttachment.lifetime = .keepAlways; add(imageAttachment)
        var colors: [String: String] = [:]
        for name in ["Background/DocumentView/colorNavPrimary", "Background/DocumentView/colorNavSecondary", "Fill/documentView/toolbarButton", "Fill/documentView/colorNavButton", "Fill/documentView/primaryColorNavContent", "Fill/documentView/secondaryColorNavContent", "Label/DocumentView/toolbarButtonActive"] {
            if let bundle = OriginalAssets.colors, let color = UIColor(named: name, in: bundle, compatibleWith: UITraitCollection(userInterfaceStyle: .dark)) { colors[name] = color.rgbHex }
        }
        let data = try JSONSerialization.data(withJSONObject: ["imageSizes": sizes, "colors": colors], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = "original-resource-values"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testExportOriginalDesignArtwork() throws {
        guard ProcessInfo.processInfo.environment["EXPORT_ORIGINAL_ARTWORK"] == "1" else { throw XCTSkip("Manual catalog export; set EXPORT_ORIGINAL_ARTWORK=1 in the test scheme to regenerate the original PNGs.") }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "original-artwork-names", withExtension: "json"))
        let requests = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        var exported: [String: [String]] = [:]
        for (catalog, names) in requests {
            let bundle = catalog == "Toolbar" ? OriginalAssets.toolbar : (catalog == "Library" ? OriginalAssets.library : OriginalAssets.icons)
            for name in names {
                autoreleasepool {
                    guard let image = OriginalAssets.image(name, in: bundle), let data = image.pngData() else { return }
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                    attachment.name = "catalog-" + catalog + "--" + name.replacingOccurrences(of: "/", with: "_")
                    attachment.lifetime = .keepAlways; add(attachment)
                    exported[catalog, default: []].append(name)
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: exported, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "decoded-original-artwork"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(exported["Toolbar", default: []].count, 100)
        XCTAssertGreaterThan(exported["Icons", default: []].count, 100)
    }
}
