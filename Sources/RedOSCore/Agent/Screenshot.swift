import CoreGraphics
import Foundation

/// An image of the frontmost window for models that can see. `frame` is the window on screen (points, top-left
/// origin, like mouse events), so a point picked in the image maps back to a click.
public struct Screenshot: Sendable, Equatable {
    public let jpeg: Data
    public let width: Int
    public let height: Int
    public let frame: CGRect

    public init(jpeg: Data, width: Int, height: Int, frame: CGRect) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.frame = frame
    }

    /// Where a pixel of the image is on screen; nil outside the image.
    public func screenPoint(x: Int, y: Int) -> CGPoint? {
        guard width > 0, height > 0, (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        return CGPoint(
            x: (frame.minX + Double(x) * frame.width / Double(width)).rounded(),
            y: (frame.minY + Double(y) * frame.height / Double(height)).rounded()
        )
    }

    /// For the model: what the image is and how to click in it.
    var note: String {
        "A screenshot of this window is attached (\(width)x\(height) pixels). Use it to understand the screen. "
            + "If what you must click is visible in it but not listed, click it by position: "
            + #"{"action":"mouse.click","arguments":{"x":<pixels from the left>,"y":<pixels from the top>}}."#
    }
}
