import AppKit

enum OCRError: LocalizedError {
    case missingConfig
    case badResponse(Int, String)
    case parseFailure
    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "OCR not configured. Edit ~/.config/snapocr/config.json (or set SNAPOCR_API_BASE / SNAPOCR_API_KEY / SNAPOCR_MODEL env vars). See config.example.json."
        case .badResponse(let code, let body): return "API \(code): \(body.prefix(400))"
        case .parseFailure: return "Could not parse response."
        }
    }
}

/// Streaming OCR via an OpenAI-format `/v1/chat/completions` endpoint with vision
/// input. Uses `stream: true` + Server-Sent Events; yields content fragments as they
/// arrive so the popup can render text live instead of blocking on the full response.
/// Endpoint, key, and model are read from Config (env vars or ~/.config/snapocr/config.json).
enum OCRService {
    static func recognize(image: CGImage) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let cfg = Config.load()
                    guard !cfg.apiBase.isEmpty, !cfg.apiKey.isEmpty, !cfg.ocrModel.isEmpty else {
                        throw OCRError.missingConfig
                    }
                    let rep = NSBitmapImageRep(cgImage: image)
                    guard let png = rep.representation(using: .png, properties: [:]) else {
                        throw OCRError.parseFailure
                    }
                    let dataURL = "data:image/png;base64,\(png.base64EncodedString())"

                    let body: [String: Any] = [
                        "model": cfg.ocrModel,
                        "max_tokens": 4096,
                        "stream": true,
                        "messages": [[
                            "role": "user",
                            "content": [
                                ["type": "text",
                                 "text": "Extract ALL text visible in this image. Preserve original line breaks and reading order. Output ONLY the extracted text — no commentary, no markdown fences."],
                                ["type": "image_url",
                                 "image_url": ["url": dataURL]]
                            ]
                        ]]
                    ]

                    let endpoint = cfg.apiBase.trimmingTrailingSlash() + "/v1/chat/completions"
                    guard let url = URL(string: endpoint) else { throw OCRError.parseFailure }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.addValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.addValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
                    req.addValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    req.timeoutInterval = 120

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw OCRError.parseFailure }
                    guard (200..<300).contains(http.statusCode) else {
                        var errBody = ""
                        for try await line in bytes.lines {
                            errBody += line + "\n"
                            if errBody.count > 800 { break }
                        }
                        throw OCRError.badResponse(http.statusCode, errBody)
                    }

                    // SSE: each event is "data: {...}\n\n". `bytes.lines` already splits on \n,
                    // so we just look for the "data: " prefix and parse the JSON payload.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                        if payload == "[DONE]" { break }
                        guard let pdata = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else { continue }
                        if let chunk = delta["content"] as? String, !chunk.isEmpty {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
