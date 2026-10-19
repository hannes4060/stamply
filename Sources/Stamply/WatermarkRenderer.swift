import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum WatermarkError: LocalizedError {
    case cannotRead
    case cannotDecode
    case cannotCreateContext
    case cannotWrite
    case logoMissing

    var errorDescription: String? {
        switch self {
        case .cannotRead: return "Datei konnte nicht gelesen werden."
        case .cannotDecode: return "Bild konnte nicht dekodiert werden."
        case .cannotCreateContext: return "Zeichenfläche konnte nicht erstellt werden."
        case .cannotWrite: return "Datei konnte nicht geschrieben werden."
        case .logoMissing: return "Logo-Datei fehlt oder ist nicht lesbar."
        }
    }
}

/// Setzt das Wasserzeichen auf ein einzelnes Bild. Unveränderlich, daher
/// gefahrlos aus mehreren Threads gleichzeitig nutzbar.
struct WatermarkRenderer: @unchecked Sendable {
    let settings: WatermarkSettings
    let logo: CGImage?

    init(settings: WatermarkSettings) throws {
        self.settings = settings
        if settings.usesLogo {
            guard let path = settings.logoPath,
                  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw WatermarkError.logoMissing
            }
            logo = image
        } else {
            logo = nil
        }
    }

    // MARK: Verarbeitung

    func process(input: URL, output: URL) throws {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(input as CFURL, sourceOptions),
              let sourceType = CGImageSourceGetType(source) as String? else {
            throw WatermarkError.cannotRead
        }

        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let pixelW = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelH = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxSide = max(pixelW, pixelH)
        guard maxSide > 0 else { throw WatermarkError.cannotDecode }

        // Volle Auflösung, EXIF-Ausrichtung direkt angewendet → Bild steht aufrecht
        // und das Wasserzeichen landet dort, wo man es erwartet.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
            throw WatermarkError.cannotDecode
        }

        let width = image.width
        let height = image.height

        // Farbraum des Originals behalten (iPhone-Fotos: Display P3).
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        var colorSpace = image.colorSpace ?? srgb
        if colorSpace.model != .rgb { colorSpace = srgb }

        let hasAlpha: Bool = {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return sourceType == UTType.png.identifier
            }
        }()
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: alphaInfo.rawValue) else {
            throw WatermarkError.cannotCreateContext
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        drawWatermark(in: ctx, width: CGFloat(width), height: CGFloat(height))

        guard let result = ctx.makeImage() else { throw WatermarkError.cannotCreateContext }

        try write(result, to: output, sourceType: sourceType, sourceProps: props)

        if settings.keepFileDates {
            copyFileDates(from: input, to: output)
        }
    }

    // MARK: Schreiben

    private func outputType(for sourceType: String) -> String {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        if writable.contains(sourceType) { return sourceType }
        if let t = UTType(sourceType), t.conforms(to: .heif), writable.contains(UTType.heic.identifier) {
            return UTType.heic.identifier
        }
        return UTType.jpeg.identifier
    }

    private func write(_ image: CGImage, to url: URL, sourceType: String, sourceProps: [CFString: Any]) throws {
        let type = outputType(for: sourceType)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw WatermarkError.cannotWrite
        }

        var meta: [CFString: Any] = [:]
        if settings.keepMetadata {
            meta = sourceProps
            if settings.removeGPS {
                meta.removeValue(forKey: kCGImagePropertyGPSDictionary)
            }
            if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                meta[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = meta[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                meta[kCGImagePropertyExifDictionary] = exif
            }
        }
        // Pixel sind bereits aufrecht gedreht.
        meta[kCGImagePropertyOrientation] = 1
        meta[kCGImageDestinationLossyCompressionQuality] = settings.quality

        CGImageDestinationAddImage(dest, image, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw WatermarkError.cannotWrite
        }
    }

    private func copyFileDates(from source: URL, to target: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: source.path) else { return }
        var newAttrs: [FileAttributeKey: Any] = [:]
        if let c = attrs[.creationDate] { newAttrs[.creationDate] = c }
        if let m = attrs[.modificationDate] { newAttrs[.modificationDate] = m }
        try? fm.setAttributes(newAttrs, ofItemAtPath: target.path)
    }

    // MARK: Zeichnen

    private struct Layout {
        var line: CTLine?
        var textWidth: CGFloat = 0
        var textHeight: CGFloat = 0
        var descent: CGFloat = 0
        var logoSize: CGSize = .zero
        var gap: CGFloat = 0
        var size: CGSize = .zero
    }

    private func makeLine(fontSize: CGFloat) -> CTLine {
        var traits: [CFString: Any] = [:]
        if settings.bold {
            traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitBold.rawValue
        }
        let fontAttributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: settings.fontFamily,
            kCTFontTraitsAttribute: traits,
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(fontAttributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): settings.textColor.cgColor,
        ]
        let string = NSAttributedString(string: settings.trimmedText, attributes: attributes)
        return CTLineCreateWithAttributedString(string)
    }

    private func makeLayout(unit: CGFloat) -> Layout {
        var layout = Layout()
        let fontSize = unit * settings.textSizePercent / 100
        let showText = settings.usesText && !settings.trimmedText.isEmpty
        let showLogo = settings.usesLogo && logo != nil

        if showText {
            let line = makeLine(fontSize: fontSize)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            layout.textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            layout.textHeight = ascent + descent
            layout.descent = descent
            layout.line = line
        }
        if showLogo, let logo, logo.width > 0 {
            let w = unit * settings.logoSizePercent / 100
            layout.logoSize = CGSize(width: w, height: w * CGFloat(logo.height) / CGFloat(logo.width))
        }
        if showText && showLogo {
            layout.gap = fontSize * 0.35
        }
        layout.size = CGSize(width: max(layout.textWidth, layout.logoSize.width),
                             height: layout.textHeight + layout.gap + layout.logoSize.height)
        return layout
    }

    private func drawWatermark(in ctx: CGContext, width W: CGFloat, height H: CGFloat) {
        let unit = min(W, H)
        let layout = makeLayout(unit: unit)
        guard layout.size.width > 0, layout.size.height > 0 else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Deckkraft und Schatten wirken auf das gesamte Wasserzeichen als Einheit.
        ctx.setAlpha(CGFloat(settings.opacity))
        if settings.shadow {
            let base = layout.line != nil
                ? unit * settings.textSizePercent / 100
                : layout.logoSize.height * 0.25
            ctx.setShadow(offset: CGSize(width: base * 0.04, height: -base * 0.04),
                          blur: base * 0.15,
                          color: CGColor(gray: 0, alpha: 0.55))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        if settings.tiled {
            drawTiled(in: ctx, W: W, H: H, unit: unit, layout: layout)
        } else {
            let margin = unit * settings.marginPercent / 100
            let size = layout.size
            let x: CGFloat
            switch settings.position.horizontal {
            case .left: x = margin
            case .center: x = (W - size.width) / 2
            case .right: x = W - margin - size.width
            }
            let y: CGFloat // Ursprung unten links
            switch settings.position.vertical {
            case .top: y = H - margin - size.height
            case .middle: y = (H - size.height) / 2
            case .bottom: y = margin
            }
            drawBlock(in: ctx, at: CGPoint(x: x, y: y), layout: layout,
                      align: settings.position.horizontal)
        }

        ctx.endTransparencyLayer()
    }

    private func drawTiled(in ctx: CGContext, W: CGFloat, H: CGFloat, unit: CGFloat, layout: Layout) {
        ctx.translateBy(x: W / 2, y: H / 2)
        ctx.rotate(by: CGFloat(settings.tileAngle) * .pi / 180)

        let spacing = max(unit * settings.tileSpacingPercent / 100, 1)
        let stepX = layout.size.width + spacing
        let stepY = layout.size.height + spacing
        let radius = hypot(W, H) / 2

        var row = 0
        var y = -radius - stepY
        while y < radius {
            let shift = row.isMultiple(of: 2) ? 0 : stepX / 2
            var x = -radius - stepX + shift
            while x < radius {
                drawBlock(in: ctx, at: CGPoint(x: x, y: y), layout: layout, align: .center)
                x += stepX
            }
            y += stepY
            row += 1
        }
    }

    /// Zeichnet Logo (oben) und Text (unten) als Block mit Ursprung unten links.
    private func drawBlock(in ctx: CGContext, at origin: CGPoint, layout: Layout,
                           align: WatermarkPosition.Horizontal) {
        func offset(_ w: CGFloat) -> CGFloat {
            switch align {
            case .left: return 0
            case .center: return (layout.size.width - w) / 2
            case .right: return layout.size.width - w
            }
        }

        if let logo, layout.logoSize.width > 0 {
            let rect = CGRect(x: origin.x + offset(layout.logoSize.width),
                              y: origin.y + layout.textHeight + layout.gap,
                              width: layout.logoSize.width,
                              height: layout.logoSize.height)
            ctx.draw(logo, in: rect)
        }
        if let line = layout.line {
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: origin.x + offset(layout.textWidth),
                                       y: origin.y + layout.descent)
            CTLineDraw(line, ctx)
        }
    }
}
