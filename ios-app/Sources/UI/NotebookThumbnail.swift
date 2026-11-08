import SwiftUI
import PDFKit
import PencilKit

@MainActor enum NotebookThumbnail {
    static func render(page: NotebookPage, directory: URL, width: CGFloat = 160) throws -> UIImage {
        let bounds = CGRect(origin: .zero, size: page.nativeSize)
        let ink = try NotebookArchive.originalInk(page: page, directory: directory)
        let drawing = try DrawingDisk.load(directory, page.id)
        let textURL = directory.appendingPathComponent(page.id + ".texts.json")
        let texts = FileManager.default.fileExists(atPath: textURL.path) ? try JSONDecoder().decode([TextBox].self, from: Data(contentsOf: textURL)) : []
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let scale = width / page.size.width
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: page.size.height * scale), format: format).image { context in
            let c = context.cgContext; c.scaleBy(x: scale, y: scale); page.applyRotation(to: c)
            UIColor(hex: page.paperColor ?? "#FFFFFF").setFill(); c.fill(bounds)
            if let name = page.pdf, let document = PDFDocument(url: directory.appendingPathComponent(name)), let pdf = document.page(at: page.pdfPage) {
                c.saveGState(); c.translateBy(x: 0, y: bounds.height); c.scaleBy(x: 1, y: -1)
                let box = pdf.bounds(for: .cropBox)
                if box.width > 0, box.height > 0 { c.scaleBy(x: bounds.width / box.width, y: bounds.height / box.height); c.translateBy(x: -box.minX, y: -box.minY); pdf.draw(with: .cropBox, to: c) }
                c.restoreGState()
            } else { PaperView.paint(c, bounds: bounds, paper: page.paper) }
            for stroke in ink.strokes {
                c.saveGState(); c.setFillColor(stroke.color.cgColor); c.setStrokeColor(stroke.color.cgColor); c.setLineWidth(stroke.width); c.setLineCap(.round); c.setLineJoin(.round); c.addPath(stroke.path)
                if stroke.filled { c.fillPath() } else { c.strokePath() }; c.restoreGState()
            }
            drawing.paperImage(from: bounds, scale: min(1, 2 * scale)).draw(in: bounds)
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
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(.white).aspectRatio(page.size.width / page.size.height, contentMode: .fit) }
        }.clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).stroke(.gray.opacity(0.5), lineWidth: 1) }
            .task(id: page) { image = try? NotebookThumbnail.render(page: page, directory: directory) }
    }
}
