import SwiftUI
import UIKit
import ARKit
import CoreImage
import ImageIO

// MARK: - Condivisione

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - File

enum FileUtils {
    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Rilievo" : cleaned
    }

    /// Crea uno zip di una cartella usando il sistema (NSFileCoordinator).
    static func zipDirectory(_ dir: URL, to dest: URL) throws {
        var coordError: NSError?
        var innerError: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { zipURL in
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: zipURL, to: dest)
            } catch {
                innerError = error
            }
        }
        if let e = coordError { throw e }
        if let e = innerError { throw e }
    }
}

// MARK: - Immagini

struct RGBAPixels {
    let data: [UInt8]
    let width: Int
    let height: Int
}

enum ImageUtils {
    static let ciContext = CIContext()

    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    static func thumbnail(at url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func rgbaPixels(_ image: CGImage) -> RGBAPixels? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? RGBAPixels(data: buffer, width: w, height: h) : nil
    }

    /// Orientamento da applicare all'immagine del sensore per averla dritta.
    @MainActor
    static func uprightOrientation() -> UIImage.Orientation {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        switch scene?.interfaceOrientation ?? .portrait {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        default: return .up
        }
    }

    @MainActor
    static func redraw(_ image: UIImage, maxSide: CGFloat?) -> UIImage {
        var size = image.size
        if let maxSide {
            let s = min(1, maxSide / max(size.width, size.height))
            size = CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Foto annotate

enum PhotoSaver {
    /// Salva la foto del fotogramma corrente nella cartella del progetto.
    @MainActor
    static func save(frame: ARFrame, projectFolder: URL, source: String) -> PhotoRecord? {
        guard let cg = ImageUtils.cgImage(from: frame.capturedImage) else { return nil }
        let oriented = UIImage(cgImage: cg, scale: 1, orientation: ImageUtils.uprightOrientation())
        let id = UUID()
        let dir = projectFolder.appendingPathComponent("foto", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = "foto/\(id.uuidString).jpg"
        let thumb = "foto/\(id.uuidString)_mini.jpg"
        let full = ImageUtils.redraw(oriented, maxSide: nil)
        let small = ImageUtils.redraw(oriented, maxSide: 360)
        guard let fullData = full.jpegData(compressionQuality: 0.9),
              let smallData = small.jpegData(compressionQuality: 0.8) else { return nil }
        do {
            try fullData.write(to: projectFolder.appendingPathComponent(file))
            try smallData.write(to: projectFolder.appendingPathComponent(thumb))
        } catch {
            return nil
        }
        let t = frame.camera.transform.translation
        return PhotoRecord(id: id, file: file, thumbFile: thumb, note: "", date: Date(),
                           position: [t.x, t.y, t.z], source: source)
    }
}
