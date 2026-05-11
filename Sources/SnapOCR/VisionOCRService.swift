import AppKit
import Vision

enum VisionOCRError: LocalizedError {
    case requestFailed(String)
    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): return "Vision OCR failed: \(msg)"
        }
    }
}

/// On-device OCR via Apple's Vision framework. No network, no API key, ~50-200ms
/// per call. Auto-detects language. Less robust than LLM-OCR on tables / handwriting /
/// low-contrast text, but great for normal screenshots of code, articles, UI strings.
enum VisionOCRService {
    static func recognize(image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate          // .accurate > .fast (~3x slower, much better)
        request.usesLanguageCorrection = true
        // Pin recognition languages explicitly — Vision's auto-detect tends to misclassify
        // mixed content. Listing the common ones gets reliable results for typical screenshots.
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw VisionOCRError.requestFailed(error.localizedDescription)
        }

        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
