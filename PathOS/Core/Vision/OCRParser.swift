import UIKit
import Vision

nonisolated struct OCRLine: Hashable, Sendable {
    var text: String
    var confidence: Float
    /// Normalized, Vision coordinates (origin bottom-left).
    var boundingBox: CGRect
}

nonisolated struct OCRResult: Sendable {
    var lines: [OCRLine]

    var fullText: String { lines.map(\.text).joined(separator: "\n") }
    var isEmpty: Bool { lines.isEmpty }
}

nonisolated enum OCRParser {
    enum OCRError: LocalizedError {
        case invalidImage

        var errorDescription: String? { "That image couldn't be read." }
    }

    /// Extracts text lines from a poster, receipt or parking sign in reading order.
    static func recognizeText(in image: UIImage) async throws -> OCRResult {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let observations = try await request.perform(on: cgImage, orientation: orientation(for: image.imageOrientation))
        let lines = observations.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox.cgRect
            )
        }

        // Top-to-bottom, then left-to-right.
        let ordered = lines.sorted { first, second in
            if abs(first.boundingBox.maxY - second.boundingBox.maxY) > 0.015 {
                return first.boundingBox.maxY > second.boundingBox.maxY
            }
            return first.boundingBox.minX < second.boundingBox.minX
        }
        return OCRResult(lines: ordered)
    }

    static func orientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
