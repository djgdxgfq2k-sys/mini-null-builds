import SwiftUI
import VisionKit
import UIKit

@MainActor enum DocumentMediaPDF {
    static var canScan: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return VNDocumentCameraViewController.isSupported
        #endif
    }
    static var canUseCamera: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }
    static func write(_ images: [UIImage]) throws -> URL {
        guard let first = images.first, first.size.width > 0, first.size.height > 0 else { throw NotebookError.invalid("Kein Bild ausgewählt.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        try renderer.writePDF(to: url) { context in
            for image in images where image.size.width > 0 && image.size.height > 0 {
                let scale = min(595 / image.size.width, 14400 / image.size.height)
                let bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                context.beginPage(withBounds: bounds, pageInfo: [:]); UIColor.white.setFill(); context.cgContext.fill(bounds); image.draw(in: bounds)
            }
        }
        return url
    }
}

#if !targetEnvironment(macCatalyst)
struct DocumentScanner: UIViewControllerRepresentable {
    let completion: (Result<[UIImage], Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController { let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator; return controller }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<[UIImage], Error>) -> Void
        init(completion: @escaping (Result<[UIImage], Error>) -> Void) { self.completion = completion }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(.success([])) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { completion(.failure(error)) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) { completion(.success((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })) }
    }
}

struct DocumentCamera: UIViewControllerRepresentable {
    let completion: ([UIImage]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let controller = UIImagePickerController(); controller.sourceType = .camera; controller.delegate = context.coordinator; return controller }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: ([UIImage]) -> Void
        init(completion: @escaping ([UIImage]) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion([]) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { completion((info[.originalImage] as? UIImage).map { [$0] } ?? []) }
    }
}
#else
struct DocumentScanner: View {
    let completion: (Result<[UIImage], Error>) -> Void
    var body: some View { CameraUnavailableView() }
}
struct DocumentCamera: View {
    let completion: ([UIImage]) -> Void
    var body: some View { CameraUnavailableView() }
}
private struct CameraUnavailableView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { VStack { ContentUnavailableView("Kamera nicht verfügbar", systemImage: "camera"); Button("Schließen") { dismiss() } } }
}
#endif
