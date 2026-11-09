import SwiftUI
import PDFKit
import PencilKit

/// Page previews for the library, the page sidebar and popovers. Rendering reads PDFs, ink and
/// sometimes the original archive, so it never runs on the main thread: previews are drawn on a small
/// background queue and kept in memory and on disk until the page or its ink changes.
enum NotebookThumbnail {
    private static let memory: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.countLimit = 400; return c }()
    private static let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q }()
    private static let pdfLock = NSLock()
    private static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Stable key: page metadata plus when its ink and text boxes last changed.
    static func key(page: NotebookPage, directory: URL, width: CGFloat) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix<S: Sequence>(_ bytes: S) where S.Element == UInt8 { for b in bytes { hash = (hash ^ UInt64(b)) &* 0x100000001b3 } }
        if let meta = try? JSONEncoder().encode(page) { mix(meta) }
        mix(directory.lastPathComponent.utf8)
        for name in [page.id + ".drawing", page.id + ".texts.json"] {
            if let date = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { mix(String(date.timeIntervalSince1970).utf8) }
        }
        return "\(page.id)-\(Int(width))-\(String(hash, radix: 16))"
    }

    static func cached(_ key: String) -> UIImage? { memory.object(forKey: key as NSString) }

    static func image(page: NotebookPage, directory: URL, width: CGFloat = 160) async -> UIImage? {
        let key = key(page: page, directory: directory, width: width)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                let file = folder.appendingPathComponent(key + ".jpg")
                if let data = try? Data(contentsOf: file), let stored = UIImage(data: data, scale: 2) {
                    memory.setObject(stored, forKey: key as NSString); continuation.resume(returning: stored); return
                }
                let image = try? render(page: page, directory: directory, width: width)
                if let image {
                    memory.setObject(image, forKey: key as NSString)
                    if let jpeg = image.jpegData(compressionQuality: 0.85) { try? jpeg.write(to: file, options: .atomic) }
                }
                continuation.resume(returning: image)
            }
        }
    }

    static func render(page: NotebookPage, directory: URL, width: CGFloat = 160) throws -> UIImage {
        let bounds = CGRect(origin: .zero, size: page.nativeSize)
        let ink = try NotebookArchive.originalInk(page: page, directory: directory)
        let drawing = try DrawingDisk.load(directory, page.id)
        let textURL = directory.appendingPathComponent(page.id + ".texts.json")
        let texts = FileManager.default.fileExists(atPath: textURL.path) ? try JSONDecoder().decode([TextBox].self, from: Data(contentsOf: textURL)) : []
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let scale = width / page.size.width
        let inkImage = drawing.strokes.isEmpty ? nil : drawing.paperImage(from: bounds, scale: min(2, 2 * scale))
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: page.size.height * scale), format: format).image { context in
            let c = context.cgContext; c.scaleBy(x: scale, y: scale); page.applyRotation(to: c)
            UIColor(hex: page.paperColor ?? "#FFFFFF").setFill(); c.fill(bounds)
            if let name = page.pdf, let document = PDFDocument(url: directory.appendingPathComponent(name)), let pdf = document.page(at: page.pdfPage) {
                c.saveGState(); c.translateBy(x: 0, y: bounds.height); c.scaleBy(x: 1, y: -1)
                let box = pdf.bounds(for: .cropBox)
                if box.width > 0, box.height > 0 {
                    c.scaleBy(x: bounds.width / box.width, y: bounds.height / box.height); c.translateBy(x: -box.minX, y: -box.minY)
                    pdfLock.lock(); pdf.draw(with: .cropBox, to: c); pdfLock.unlock()
                }
                c.restoreGState()
            } else { PaperView.paint(c, bounds: bounds, paper: page.paper) }
            ink.draw(in: c)
            inkImage?.draw(in: bounds)
            for box in texts {
                if let color = box.color { UIColor(hex: color).setFill(); UIRectFill(CGRect(x: box.x, y: box.y, width: box.width, height: box.height)) }
                let inset = box.color == nil ? UIEdgeInsets(top: 8, left: 5, bottom: 0, right: 5) : TextBox.stickyInset
                (box.text as NSString).draw(in: CGRect(x: box.x + inset.left, y: box.y + inset.top, width: max(1, box.width - inset.left - inset.right), height: box.height - inset.top), withAttributes: [.font: UIFont.systemFont(ofSize: box.fontSize.map { CGFloat($0) } ?? (box.color == nil ? 20 : TextBox.stickyFont)), .foregroundColor: UIColor(hex: "#1E1B1B")])
            }
        }
    }
}

@MainActor struct NotebookPreview: View {
    let page: NotebookPage
    let directory: URL
    /// Library cards show the notebook's cover when it has one.
    var cover = false
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().transition(.opacity) }
            else { Rectangle().fill(.white).aspectRatio(page.size.width / page.size.height, contentMode: .fit) }
        }.clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).stroke(.gray.opacity(0.5), lineWidth: 1) }
            .task(id: page) {
                if cover, NotebookCover.exists(directory), let art = await NotebookCover.image(directory) { image = art; return }
                if image == nil, let hit = NotebookThumbnail.cached(NotebookThumbnail.key(page: page, directory: directory, width: 160)) { image = hit; return }
                let rendered = await NotebookThumbnail.image(page: page, directory: directory)
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.15)) { image = rendered } }
            }
    }
}

/// A notebook's cover, shown in the library instead of its first page like Goodnotes does: the original
/// Goodnotes cover for imported notebooks, or a plain cloth cover chosen when a notebook is created.
enum NotebookCover {
    static let fileName = "cover.jpg"
    /// Cover colours offered when creating a notebook (Goodnotes' plain covers).
    static let colors = ["#754000", "#57D9F5", "#2E4A7D", "#C0392B", "#2F7D4A", "#1D1B1B", "#E9B949", "#8E5BB5"]
    private static let memory = NSCache<NSURL, UIImage>()
    static func url(_ directory: URL) -> URL { directory.appendingPathComponent(fileName) }
    static func exists(_ directory: URL) -> Bool { FileManager.default.fileExists(atPath: url(directory).path) }
    static func image(_ directory: URL) async -> UIImage? {
        let file = url(directory)
        if let hit = memory.object(forKey: file as NSURL) { return hit }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file), let image = UIImage(data: data)?.preparingForDisplay() else { return nil }
            memory.setObject(image, forKey: file as NSURL); return image
        }.value
    }
    /// Solid cloth with the darker elastic band near the right edge.
    static func make(color: String) -> Data? {
        let size = CGSize(width: 386, height: 500)
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let base = UIColor(hex: color)
            base.setFill(); context.fill(CGRect(origin: .zero, size: size))
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
            UIColor(hue: h, saturation: min(1, sat * 1.1), brightness: b * 0.62, alpha: 1).setFill()
            context.fill(CGRect(x: 328, y: 0, width: 19, height: size.height))
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}
