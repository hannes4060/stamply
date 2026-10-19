import Foundation
import AppKit

// MARK: - Einstellungen

enum WatermarkKind: String, Codable, CaseIterable, Identifiable {
    case text, logo, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: return "Text"
        case .logo: return "Logo"
        case .both: return "Text + Logo"
        }
    }
}

enum WatermarkPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Oben links"
        case .top: return "Oben Mitte"
        case .topRight: return "Oben rechts"
        case .left: return "Mitte links"
        case .center: return "Mitte"
        case .right: return "Mitte rechts"
        case .bottomLeft: return "Unten links"
        case .bottom: return "Unten Mitte"
        case .bottomRight: return "Unten rechts"
        }
    }

    enum Horizontal { case left, center, right }
    enum Vertical { case top, middle, bottom }

    var horizontal: Horizontal {
        switch self {
        case .topLeft, .left, .bottomLeft: return .left
        case .top, .center, .bottom: return .center
        case .topRight, .right, .bottomRight: return .right
        }
    }

    var vertical: Vertical {
        switch self {
        case .topLeft, .top, .topRight: return .top
        case .left, .center, .right: return .middle
        case .bottomLeft, .bottom, .bottomRight: return .bottom
        }
    }
}

/// Farbe im sRGB-Raum, speicherbar als JSON.
struct RGBAColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let white = RGBAColor(r: 1, g: 1, b: 1, a: 1)

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

extension RGBAColor {
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.white
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent),
                  b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }
}

struct WatermarkSettings: Codable, Equatable {
    // Art
    var kind: WatermarkKind = .text

    // Text
    var text: String = "© Ihr Name"
    var fontFamily: String = "Helvetica Neue"
    var bold: Bool = true
    /// Schriftgröße in Prozent der kürzeren Bildseite
    var textSizePercent: Double = 4
    var textColor: RGBAColor = .white
    var shadow: Bool = true

    // Logo
    var logoPath: String? = nil
    /// Logobreite in Prozent der kürzeren Bildseite
    var logoSizePercent: Double = 20

    // Platzierung
    var position: WatermarkPosition = .bottomRight
    /// Randabstand in Prozent der kürzeren Bildseite
    var marginPercent: Double = 3
    var tiled: Bool = false
    var tileSpacingPercent: Double = 12
    var tileAngle: Double = 30

    // Darstellung
    var opacity: Double = 0.7

    // Export
    var quality: Double = 0.9
    var keepMetadata: Bool = true
    var removeGPS: Bool = true
    var keepFileDates: Bool = true
    var fileSuffix: String = ""

    var trimmedText: String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    var usesText: Bool { kind != .logo }
    var usesLogo: Bool { kind != .text }

    /// Fehlermeldung, falls die Einstellungen so nicht verarbeitet werden können.
    var validationError: String? {
        if usesText && trimmedText.isEmpty && kind == .text {
            return "Bitte einen Text für das Wasserzeichen eingeben."
        }
        if usesLogo {
            guard let path = logoPath, FileManager.default.fileExists(atPath: path) else {
                return "Bitte eine Logo-Datei wählen."
            }
        }
        return nil
    }

    // Robust gegenüber älteren gespeicherten Einstellungen mit fehlenden Feldern.
    init() {}

    init(from decoder: Decoder) throws {
        let d = WatermarkSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(WatermarkKind.self, forKey: .kind)) ?? d.kind
        text = (try? c.decode(String.self, forKey: .text)) ?? d.text
        fontFamily = (try? c.decode(String.self, forKey: .fontFamily)) ?? d.fontFamily
        bold = (try? c.decode(Bool.self, forKey: .bold)) ?? d.bold
        textSizePercent = (try? c.decode(Double.self, forKey: .textSizePercent)) ?? d.textSizePercent
        textColor = (try? c.decode(RGBAColor.self, forKey: .textColor)) ?? d.textColor
        shadow = (try? c.decode(Bool.self, forKey: .shadow)) ?? d.shadow
        logoPath = try? c.decode(String.self, forKey: .logoPath)
        logoSizePercent = (try? c.decode(Double.self, forKey: .logoSizePercent)) ?? d.logoSizePercent
        position = (try? c.decode(WatermarkPosition.self, forKey: .position)) ?? d.position
        marginPercent = (try? c.decode(Double.self, forKey: .marginPercent)) ?? d.marginPercent
        tiled = (try? c.decode(Bool.self, forKey: .tiled)) ?? d.tiled
        tileSpacingPercent = (try? c.decode(Double.self, forKey: .tileSpacingPercent)) ?? d.tileSpacingPercent
        tileAngle = (try? c.decode(Double.self, forKey: .tileAngle)) ?? d.tileAngle
        opacity = (try? c.decode(Double.self, forKey: .opacity)) ?? d.opacity
        quality = (try? c.decode(Double.self, forKey: .quality)) ?? d.quality
        keepMetadata = (try? c.decode(Bool.self, forKey: .keepMetadata)) ?? d.keepMetadata
        removeGPS = (try? c.decode(Bool.self, forKey: .removeGPS)) ?? d.removeGPS
        keepFileDates = (try? c.decode(Bool.self, forKey: .keepFileDates)) ?? d.keepFileDates
        fileSuffix = (try? c.decode(String.self, forKey: .fileSuffix)) ?? d.fileSuffix
    }
}

// MARK: - Dateiliste

struct PhotoItem: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case working
        case done(URL)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var status: Status = .pending
}

enum SupportedFormats {
    static let extensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png"]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
