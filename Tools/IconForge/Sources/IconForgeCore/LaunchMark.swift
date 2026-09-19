import CoreGraphics
import Foundation

/// The mark on its own, for the launch screen: the icon's glass figure with no tile behind it,
/// the way apps open to their logo rather than to their home-screen square.
///
/// It's cut from the same render as the icon, so the two can't drift apart.
public enum LaunchMark {
    /// Its width on screen, in points; the height follows the logo's proportions. The in-app launch
    /// view shows the image at its natural size, so changing this needs no code change there.
    public static let widthPoints = 140

    /// The size in points for a mark of this shape.
    public static func points(for mark: CGImage) -> (width: Int, height: Int) {
        let height = Double(widthPoints) * Double(mark.height) / Double(mark.width)
        return (widthPoints, Int(height.rounded()))
    }

    /// Writes an asset-catalog image set with @2x and @3x copies.
    public static func write(_ mark: CGImage, toImageSet folder: URL) throws {
        let size = points(for: mark)
        for scale in [2, 3] {
            try Raster.writePNG(Raster.resized(mark, width: size.width * scale, height: size.height * scale),
                                to: folder.appendingPathComponent("LaunchMark@\(scale)x.png"),
                                keepingAlpha: true)
        }
        let contents = """
        {
          "images" : [
            { "idiom" : "universal", "scale" : "1x" },
            { "filename" : "LaunchMark@2x.png", "idiom" : "universal", "scale" : "2x" },
            { "filename" : "LaunchMark@3x.png", "idiom" : "universal", "scale" : "3x" }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }

        """
        try Data(contents.utf8).write(to: folder.appendingPathComponent("Contents.json"))
    }
}
