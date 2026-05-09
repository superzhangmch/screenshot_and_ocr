import AppKit

enum ClipboardService {
    static func copy(image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let img = NSImage(data: png) ?? NSImage()
        pb.writeObjects([img])
        pb.setData(png, forType: .png)
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
