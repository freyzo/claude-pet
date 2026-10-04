import AppKit
import XCTest

final class AlphaMaskTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 160, height: 160)

    /// Independent reference: draw into RGBA and read alpha directly.
    private func alpha(_ image: CGImage, x: Int, yFromTop: Int) -> UInt8 {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels[(yFromTop * image.width + x) * 4 + 3]
    }

    func testMasksMatchDirectPixelReadsForEverySpriteFrame() {
        for name in ["stitch_idle", "stitch_walk1", "stitch_walk2", "claude_idle", "claude_walk1", "claude_walk2"] {
            let image = TestSupport.sprite(name)
            let mask = AlphaMask(image: image)!
            let scale = CGFloat(image.width) / bounds.width
            var mismatches = 0
            for vy in stride(from: 0.5, to: 160, by: 8.0) {
                for vx in stride(from: 0.5, to: 160, by: 8.0) {
                    for mirrored in [false, true] {
                        let sourceX = mirrored ? 160 - vx : vx
                        let expected = alpha(image, x: Int(sourceX * scale), yFromTop: image.height - 1 - Int(vy * scale)) > 30
                        if mask.isOpaque(at: CGPoint(x: vx, y: vy), in: bounds, mirrored: mirrored) != expected { mismatches += 1 }
                    }
                }
            }
            XCTAssertEqual(mismatches, 0, name)
            XCTAssertFalse(mask.isOpaque(at: CGPoint(x: 1, y: 159), in: bounds, mirrored: false), "\(name) corner")
            XCTAssertFalse(mask.isOpaque(at: CGPoint(x: 200, y: 50), in: bounds, mirrored: false), "\(name) outside")
        }
    }

    func testNonSquareImageIsLetterboxedAndMirrored() {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))  // left half solid
        let mask = AlphaMask(image: ctx.makeImage()!)!
        XCTAssertFalse(mask.isOpaque(at: CGPoint(x: 20, y: 10), in: bounds, mirrored: false), "letterbox bar")
        XCTAssertTrue(mask.isOpaque(at: CGPoint(x: 20, y: 80), in: bounds, mirrored: false))
        XCTAssertFalse(mask.isOpaque(at: CGPoint(x: 140, y: 80), in: bounds, mirrored: false))
        XCTAssertTrue(mask.isOpaque(at: CGPoint(x: 140, y: 80), in: bounds, mirrored: true))
    }
}
