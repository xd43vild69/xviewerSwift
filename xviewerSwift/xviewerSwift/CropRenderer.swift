import Foundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum CropRenderError: LocalizedError {
    case cannotReadImage
    case unsupportedForWriting(String)
    case renderFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotReadImage:
            return "Could not read the original image at full resolution."
        case .unsupportedForWriting(let ext):
            return "macOS cannot write .\(ext) files; the crop was not saved."
        case .renderFailed:
            return "Could not render the cropped image."
        case .writeFailed(let reason):
            return "Could not write the file: \(reason)"
        }
    }
}

/// Aplica el recorte + rotación sobre el archivo original, a resolución completa.
enum CropRenderer {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Recorta y **sobrescribe** el archivo original de forma atómica.
    /// Devuelve la URL del backup del original (para deshacer).
    static func applyCrop(to url: URL,
                          transform: CropTransform,
                          crop: CGRect,
                          unitSize: CGSize) throws -> URL {

        let folder = url.deletingLastPathComponent()
        let fileAccessed = url.startAccessingSecurityScopedResource()
        defer { if fileAccessed { url.stopAccessingSecurityScopedResource() } }
        let folderAccessed = folder.startAccessingSecurityScopedResource()
        defer { if folderAccessed { folder.stopAccessingSecurityScopedResource() } }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CropRenderError.cannotReadImage
        }

        let sourceType = CGImageSourceGetType(source) ?? UTType.jpeg.identifier as CFString
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1

        // 1. Imagen derecha (la orientación EXIF se hornea aquí).
        let upright = try uprightImage(original, orientation: orientation)

        // 2. Recorte + rotación.
        let cropped = try render(upright, transform: transform, crop: crop, unitSize: unitSize)

        // 3. Codificar conservando formato y metadatos.
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, sourceType, 1, nil) else {
            throw CropRenderError.unsupportedForWriting(url.pathExtension.lowercased())
        }
        properties.removeValue(forKey: kCGImagePropertyOrientation)
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        properties[kCGImagePropertyPixelWidth] = cropped.width
        properties[kCGImagePropertyPixelHeight] = cropped.height
        properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(destination, cropped, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), outputData.length > 0 else {
            throw CropRenderError.unsupportedForWriting(url.pathExtension.lowercased())
        }

        // 4. Backup del original + reemplazo atómico.
        let backup = try makeBackup(of: url)
        let tempURL = folder.appendingPathComponent(".xv_crop_\(UUID().uuidString).\(url.pathExtension)")
        do {
            try outputData.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            // replaceItemAt conserva metadatos del original; forzamos la fecha de
            // modificación para que las miniaturas cacheadas se invaliden sí o sí.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw CropRenderError.writeFailed(error.localizedDescription)
        }
        return backup
    }

    // MARK: - Pasos

    private static func uprightImage(_ image: CGImage, orientation: UInt32) throws -> CGImage {
        guard orientation != 1,
              let cgOrientation = CGImagePropertyOrientation(rawValue: orientation) else { return image }
        let oriented = CIImage(cgImage: image).oriented(cgOrientation)
        guard let result = ciContext.createCGImage(oriented, from: oriented.extent,
                                                   format: .RGBA8,
                                                   colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()) else {
            throw CropRenderError.renderFailed
        }
        return result
    }

    private static func render(_ image: CGImage,
                               transform: CropTransform,
                               crop: CGRect,
                               unitSize: CGSize) throws -> CGImage {

        let pixelsPerUnit = CGFloat(image.width) / unitSize.width
        let outWidth = max(1, (crop.width * pixelsPerUnit).rounded())
        let outHeight = max(1, (crop.height * pixelsPerUnit).rounded())

        // Camino sin pérdida: sin rotación ni flip, es una copia de píxeles.
        if transform.angle == 0 && !transform.flipH {
            let rect = CGRect(x: (crop.minX * pixelsPerUnit).rounded(),
                              y: (crop.minY * pixelsPerUnit).rounded(),
                              width: outWidth, height: outHeight)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let cropped = image.cropping(to: rect) else { throw CropRenderError.renderFailed }
            return cropped
        }

        let bounds = transform.rotatedBounds(of: unitSize)
        let boundsPx = CGSize(width: bounds.width * pixelsPerUnit, height: bounds.height * pixelsPerUnit)
        let cropX = crop.minX * pixelsPerUnit
        // El rect vive en coordenadas y-abajo; Core Image trabaja en y-arriba.
        let cropYUp = boundsPx.height - (crop.maxY * pixelsPerUnit)

        var ci = CIImage(cgImage: image)
        ci = ci.transformed(by: CGAffineTransform(translationX: -CGFloat(image.width) / 2,
                                                  y: -CGFloat(image.height) / 2))
        if transform.flipH {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        }
        // La rotación en pantalla es horaria (y-abajo) → antihoraria negativa en y-arriba.
        ci = ci.transformed(by: CGAffineTransform(rotationAngle: -transform.radians))
        ci = ci.transformed(by: CGAffineTransform(translationX: boundsPx.width / 2 - cropX,
                                                  y: boundsPx.height / 2 - cropYUp))

        let outputRect = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        guard let result = ciContext.createCGImage(ci, from: outputRect,
                                                   format: .RGBA8,
                                                   colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()) else {
            throw CropRenderError.renderFailed
        }
        return result
    }

    // MARK: - Backup

    static var backupDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("com.d13.xviewerSwift").appendingPathComponent("EditBackups")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeBackup(of url: URL) throws -> URL {
        let ext = url.pathExtension
        let name = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destination = backupDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw CropRenderError.writeFailed("could not back up the original (\(error.localizedDescription))")
        }
        return destination
    }
}
