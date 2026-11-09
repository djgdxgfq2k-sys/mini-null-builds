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
            for stroke in ink.strokes {
                c.saveGState(); c.setFillColor(stroke.color.cgColor); c.setStrokeColor(stroke.color.cgColor); c.setLineWidth(stroke.width); c.setLineCap(.round); c.setLineJoin(.round); c.addPath(stroke.path)
                if stroke.filled { c.fillPath() } else { c.strokePath() }; c.restoreGState()
            }
            inkImage?.draw(in: bounds)
            for box in texts { (box.text as NSString).draw(in: CGRect(x: box.x + 5, y: box.y + 8, width: max(1, box.width - 10), height: box.height), withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor(hex: "#1E1B1B")]) }
        }
    }
}

@MainActor struct NotebookPreview: View {
    let page: NotebookPage
    let directory: URL
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().transition(.opacity) }
            else { Rectangle().fill(.white).aspectRatio(page.size.width / page.size.height, contentMode: .fit) }
        }.clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).stroke(.gray.opacity(0.5), lineWidth: 1) }
            .task(id: page) {
                if image == nil, let hit = NotebookThumbnail.cached(NotebookThumbnail.key(page: page, directory: directory, width: 160)) { image = hit; return }
                let rendered = await NotebookThumbnail.image(page: page, directory: directory)
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.15)) { image = rendered } }
            }
    }
}
