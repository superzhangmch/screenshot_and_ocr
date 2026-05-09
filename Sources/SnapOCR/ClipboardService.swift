import AppKit

enum ClipboardService {
    static func copy(image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        // Just the raw bytes — most apps prefer .png/.tiff. Skipping the NSImage roundtrip
        // avoids leaving an extra object resident on the pasteboard's promise list.
        pb.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
