import CoreImage
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// The tables in a photo, as rows and columns of cell text, with where each line of text sits.
///
/// Reading a photo's text as lines loses which cell is under which heading, which is everything
/// in a timetable. Vision's document reader keeps the grid; `TimetableGrid` then re-cuts it by the
/// text's position where the reader's cells come out wrong.
nonisolated enum TableReader {
    /// Every table found, read from the photo as it is and from the photo squared up to its page.
    /// Squaring up rescues a page shot at an angle but blurs one that was already flat, and the
    /// two can't be told apart reliably beforehand, so both are read and the caller keeps
    /// whichever gives the fuller timetable.
    static func tables(in image: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> [TimetableGrid] {
        var grids: [TimetableGrid] = []
        for version in await versions(of: image, orientation: orientation) {
            grids += try await tables(in: version)
        }
        return grids
    }

    private static func tables(in image: CGImage) async throws -> [TimetableGrid] {
        var request = RecognizeDocumentsRequest()
        // Timetables here are in English; guessing the language let a "3" come back as a
        // Cyrillic "З".
        request.textRecognitionOptions.automaticallyDetectLanguage = false
        request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        request.textRecognitionOptions.useLanguageCorrection = true
        let documents = try await request.perform(on: image)
        return documents.flatMap(\.document.tables).map(grid(from:))
    }

    static func grid(from table: DocumentObservation.Container.Table) -> TimetableGrid {
        TimetableGrid(cells: table.rows.flatMap { $0 }.map { cell in
            let lines = cell.content.text.lines.compactMap { line -> (text: String, x: Double, y: Double)? in
                guard let text = line.topCandidates(1).first?.string else { return nil }
                let box = line.boundingBox.cgRect
                return (text, Double(box.midX), Double(box.midY))
            }
            let box = cell.content.boundingRegion.boundingBox.cgRect
            return TimetableGrid.Cell(
                rows: cell.rowRange,
                columns: cell.columnRange,
                lines: lines.map(\.text),
                lineCenters: lines.map(\.x),
                lineHeights: lines.map(\.y),
                xExtent: Double(box.minX)...Double(box.maxX),
                yExtent: Double(box.minY)...Double(box.maxY)
            )
        })
    }

    // MARK: Straightening

    /// The photo levelled, and, when Vision finds a page seen at an angle, also squared up to it
    /// and levelled. Vision reads a table's rows by height on the page, so on a tilted photo each
    /// row picks up cells from the rows beside it.
    static func versions(of image: CGImage, orientation: CGImagePropertyOrientation) async -> [CGImage] {
        let context = CIContext()
        var picture = CIImage(cgImage: image).oriented(orientation)
        picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))

        var pictures = [picture]
        if let upright = context.createCGImage(picture, from: picture.extent),
           let page = try? await DetectDocumentSegmentationRequest().perform(on: upright),
           let squared = squaredUp(picture, to: page) {
            pictures.append(squared)
        }
        var versions: [CGImage] = []
        for picture in pictures {
            let level = await levelled(picture, context: context)
            if let version = context.createCGImage(level, from: level.extent.integral) {
                versions.append(version)
            }
        }
        return versions.isEmpty ? [image] : versions
    }

    /// Turned so its text runs level, when it leans enough to matter and not so far it's sideways.
    private static func levelled(_ picture: CIImage, context: CIContext) async -> CIImage {
        guard let upright = context.createCGImage(picture, from: picture.extent),
              let tilt = await textTilt(in: upright), abs(tilt) > 0.4 * .pi / 180, abs(tilt) < 20 * .pi / 180 else { return picture }
        let centre = CGPoint(x: picture.extent.midX, y: picture.extent.midY)
        let turn = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: -tilt)
            .translatedBy(x: -centre.x, y: -centre.y)
        let rotated = picture.transformed(by: turn)
        // Paper-white where the turn uncovers the corners, rather than transparent.
        return rotated.composited(over: CIImage(color: .white).cropped(to: rotated.extent))
    }

    /// The page squared up, when Vision finds one that fills a fair part of the photo at an angle.
    private static func squaredUp(_ picture: CIImage, to page: DetectedDocumentObservation) -> CIImage? {
        let size = picture.extent.size
        let corners = [page.topLeft, page.topRight, page.bottomRight, page.bottomLeft].map { $0.toImageCoordinates(size, origin: .lowerLeft) }
        // The shoelace formula, as a share of the photo.
        var twiceArea = 0.0
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            twiceArea += Double(a.x * b.y - b.x * a.y)
        }
        let share = abs(twiceArea) / 2 / Double(size.width * size.height)
        // A page with square corners needs nothing done to it.
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let square = [CGPoint(x: xs.min()!, y: ys.max()!), CGPoint(x: xs.max()!, y: ys.max()!),
                      CGPoint(x: xs.max()!, y: ys.min()!), CGPoint(x: xs.min()!, y: ys.min()!)]
        let skew = zip(corners, square).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
        guard share > 0.25, skew > max(size.width, size.height) * 0.01,
              let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(picture, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: corners[0]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: corners[1]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: corners[2]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: corners[3]), forKey: "inputBottomLeft")
        guard let output = filter.outputImage else { return nil }
        return output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
    }

    /// The text's slope in radians, from the middle of its lines' slopes.
    private static func textTilt(in image: CGImage) async -> Double? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .fast
        guard let lines = try? await request.perform(on: image) else { return nil }
        let width = Double(image.width), height = Double(image.height)
        let slopes = lines.compactMap { line -> Double? in
            let left = line.topLeft.cgPoint, right = line.topRight.cgPoint
            let dx = Double(right.x - left.x) * width, dy = Double(right.y - left.y) * height
            // Short words give noisy angles.
            guard dx > 60 else { return nil }
            return atan2(dy, dx)
        }.sorted()
        guard slopes.count >= 5 else { return nil }
        return slopes[slopes.count / 2]
    }
}

#if canImport(UIKit)
extension TableReader {
    static func tables(in image: UIImage) async throws -> [TimetableGrid] {
        guard let cgImage = image.cgImage else { throw OCRParser.OCRError.invalidImage }
        return try await tables(in: cgImage, orientation: OCRParser.orientation(for: image.imageOrientation))
    }
}
#endif
