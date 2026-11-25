import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MeetingSnapshotEncoder {
    public struct EncodedImage: Sendable {
        public let data: Data
        public let fileExtension: String
        public let width: Int
        public let height: Int
    }

    public static func encode(
        _ image: CGImage,
        scope: MeetingSnapshotScope,
        format: MeetingSnapshotImageFormat,
        compressionQuality: Double = 0.86
    ) -> EncodedImage? {
        let requestedExtension = format.fileExtension(for: scope)
        let primaryType: UTType
        let primaryExtension: String
        switch requestedExtension {
        case "png":
            primaryType = .png
            primaryExtension = "png"
        case "heic":
            primaryType = .heic
            primaryExtension = "heic"
        default:
            primaryType = .jpeg
            primaryExtension = "jpg"
        }

        if let data = encode(image, type: primaryType, quality: compressionQuality) {
            return EncodedImage(data: data, fileExtension: primaryExtension, width: image.width, height: image.height)
        }
        if primaryType == .heic, let fallback = encode(image, type: .jpeg, quality: compressionQuality) {
            return EncodedImage(data: fallback, fileExtension: "jpg", width: image.width, height: image.height)
        }
        return nil
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = type == .png
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: min(1.0, max(0.3, quality))]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}

public enum MeetingSnapshotCompositor {
    public struct TileInput: @unchecked Sendable {
        public let image: CGImage
        public let label: String
        public let isScreenShare: Bool

        public init(image: CGImage, label: String, isScreenShare: Bool) {
            self.image = image
            self.label = label
            self.isScreenShare = isScreenShare
        }
    }

    /// Renders a clean, chrome-free stage composite from detached tile images.
    public static func composeStage(
        tiles: [TileInput],
        canvasSize: CGSize = CGSize(width: 1920, height: 1080)
    ) -> CGImage? {
        guard !tiles.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        // Flip to top-left origin for layout math.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let pad: CGFloat = 20
        let gap: CGFloat = 14
        let contentRect = CGRect(x: pad, y: pad, width: CGFloat(width) - pad * 2, height: CGFloat(height) - pad * 2)

        if let shareIndex = tiles.firstIndex(where: \.isScreenShare) {
            let share = tiles[shareIndex]
            let sideTiles = Array(tiles.enumerated().filter { $0.offset != shareIndex }.prefix(3).map(\.element))
            if sideTiles.isEmpty {
                drawAspectFit(share.image, in: contentRect, context: context)
            } else {
                let railWidth = min(380, contentRect.width * 0.24)
                let shareRect = CGRect(x: contentRect.minX, y: contentRect.minY,
                                       width: contentRect.width - railWidth - gap, height: contentRect.height)
                drawAspectFit(share.image, in: shareRect, context: context)

                let count = CGFloat(sideTiles.count)
                let tileHeight = (contentRect.height - gap * max(0, count - 1)) / max(1, count)
                for (index, tile) in sideTiles.enumerated() {
                    let rect = CGRect(
                        x: shareRect.maxX + gap,
                        y: contentRect.minY + CGFloat(index) * (tileHeight + gap),
                        width: railWidth,
                        height: tileHeight
                    )
                    drawAspectFit(tile.image, in: rect, context: context)
                }
            }
        } else {
            let visible = Array(tiles.prefix(4))
            let columns = visible.count <= 1 ? 1 : 2
            let rows = Int(ceil(Double(visible.count) / Double(columns)))
            let cellWidth = (contentRect.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (contentRect.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            for (index, tile) in visible.enumerated() {
                let col = index % columns
                let row = index / columns
                let rect = CGRect(
                    x: contentRect.minX + CGFloat(col) * (cellWidth + gap),
                    y: contentRect.minY + CGFloat(row) * (cellHeight + gap),
                    width: cellWidth,
                    height: cellHeight
                )
                drawAspectFit(tile.image, in: rect, context: context)
            }
        }

        return context.makeImage()
    }

    private static func drawAspectFit(_ image: CGImage, in rect: CGRect, context: CGContext) {
        guard image.width > 0, image.height > 0, rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil)
        context.addPath(path)
        context.clip()
        context.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1))
        context.fill(rect)

        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let drawW = CGFloat(image.width) * scale
        let drawH = CGFloat(image.height) * scale
        let drawRect = CGRect(
            x: rect.minX + (rect.width - drawW) / 2,
            y: rect.minY + (rect.height - drawH) / 2,
            width: drawW,
            height: drawH
        )
        // Undo flipped context locally when drawing CGImage so image isn't upside down.
        context.translateBy(x: drawRect.minX, y: drawRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: drawW, height: drawH))
        context.restoreGState()
    }
}
