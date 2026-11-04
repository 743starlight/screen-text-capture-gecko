import AppKit
import Vision

enum VisionOCR {
    static func validateLanguages(_ languages: [String]) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        for language in languages where !supported.contains(language) { throw OCRError.invalidLanguage(language) }
    }

    static func recognize(image: URL, languages: [String]) throws -> String {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw OCRError.invalidImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        for language in languages where !supported.contains(language) { throw OCRError.invalidLanguage(language) }
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return try OCRResult.validated(text)
    }
}

enum OCRResult {
    static func validated(_ text: String) throws -> String {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw OCRError.emptyResult }
        return result
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) throws {
        let result = try validated(text)
        pasteboard.clearContents()
        guard pasteboard.setString(result, forType: .string) else { throw OCRError.clipboardFailed }
    }
}
