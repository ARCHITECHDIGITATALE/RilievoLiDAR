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

    /// Nitidezza: varianza del laplaciano sulla luminanza (più alto = più nitida).
    static func sharpness(_ px: RGBAPixels) -> Float {
        let w = px.width
        let h = px.height
        guard w > 4, h > 4 else { return 0 }
        func lum(_ x: Int, _ y: Int) -> Float {
            let o = (y * w + x) * 4
            return 0.299 * Float(px.data[o]) + 0.587 * Float(px.data[o + 1]) + 0.114 * Float(px.data[o + 2])
        }
        var sum: Float = 0
        var sum2: Float = 0
        var n: Float = 0
        var y = 1
        while y < h - 1 {
            var x = 1
            while x < w - 1 {
                let l = 4 * lum(x, y) - lum(x - 1, y) - lum(x + 1, y) - lum(x, y - 1) - lum(x, y + 1)
                sum += l
                sum2 += l * l
                n += 1
                x += 1
            }
            y += 1
        }
        let mean = sum / n
        return sum2 / n - mean * mean
    }

    /// Moltiplica i canali RGB per un guadagno (bilanciamento dell'esposizione tra le foto).
    static func applyGain(_ image: CGImage, _ g: SIMD3<Float>) -> CGImage {
        if abs(g.x - 1) < 0.01 && abs(g.y - 1) < 0.01 && abs(g.z - 1) < 0.01 { return image }
        let ci = CIImage(cgImage: image).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(g.x), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(g.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(g.z), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        return ciContext.createCGImage(ci, from: ci.extent) ?? image
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
