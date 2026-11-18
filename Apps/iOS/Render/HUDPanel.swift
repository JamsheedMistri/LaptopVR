import Metal
import UIKit

/// What the heads-up display says.
struct HUDContent: Equatable, Sendable {
    var title: String?
    var detail: String?
    /// Small fixed-width lines, used for statistics.
    var lines: [String] = []

    var isEmpty: Bool {
        title == nil && detail == nil && lines.isEmpty
    }
}

/// Draws the heads-up display's text into a texture, redrawing only when the text changes.
final class HUDPanel {
    static let width = 1024
    static let height = 512

    let texture: MTLTexture
    private var drawn: HUDContent?

    init?(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.width, height: Self.height, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
    }

    func show(_ content: HUDContent) {
        guard content != drawn else { return }
        drawn = content

        guard let context = CGContext(
            data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8, bytesPerRow: Self.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            // BGRA with alpha multiplied in, matching the texture and the shader's blend.
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // UIKit draws with the origin at the top, which is also the texture's first row.
        context.translateBy(x: 0, y: CGFloat(Self.height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        draw(content)
        UIGraphicsPopContext()

        guard let bytes = context.data else { return }
        texture.replace(
            region: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: context.bytesPerRow)
    }

    private func draw(_ content: HUDContent) {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center

        let text = NSMutableAttributedString()
        func append(_ string: String, font: UIFont, color: UIColor) {
            if text.length > 0 {
                text.append(NSAttributedString(string: "\n"))
            }
            text.append(NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: centered,
            ]))
        }

        if let title = content.title {
            let base = UIFont.systemFont(ofSize: 54, weight: .semibold)
            let rounded = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 54) } ?? base
            append(title, font: rounded, color: .white)
        }
        if let detail = content.detail {
            append(detail, font: .systemFont(ofSize: 32, weight: .regular), color: UIColor(white: 1, alpha: 0.7))
        }
        for line in content.lines {
            append(line, font: .monospacedDigitSystemFont(ofSize: 27, weight: .medium), color: UIColor(white: 1, alpha: 0.85))
        }
        guard text.length > 0 else { return }

        let padding: CGFloat = 36
        let canvas = CGSize(width: Self.width, height: Self.height)
        let available = CGSize(width: canvas.width - 2 * padding - 8, height: canvas.height - 2 * padding - 8)
        let bounds = text.boundingRect(with: available, options: [.usesLineFragmentOrigin], context: nil)
        let textRect = CGRect(
            x: (canvas.width - available.width) / 2,
            y: (canvas.height - ceil(bounds.height)) / 2,
            width: available.width,
            height: ceil(bounds.height)
        )

        // A dark plate just big enough for the text, so it reads against any background.
        let plate = CGRect(
            x: (canvas.width - ceil(bounds.width)) / 2 - padding,
            y: textRect.minY - padding * 0.7,
            width: ceil(bounds.width) + 2 * padding,
            height: textRect.height + 2 * padding * 0.7
        )
        UIColor(white: 0, alpha: 0.6).setFill()
        UIBezierPath(roundedRect: plate, cornerRadius: 36).fill()

        text.draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
    }
}
