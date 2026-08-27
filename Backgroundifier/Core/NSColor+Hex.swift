//
//  NSColor+Hex.swift
//  Backgroundifier
//
//  Hex color parsing/formatting shared by the app and the bgify CLI.
//  2026 upgrade by Mayk Thewessen.
//

import AppKit

extension NSColor {
    var hexString: String {
        let rgb = usingColorSpace(.sRGB) ?? self
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }

    convenience init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value & 0xFF0000) >> 16) / 255,
            green: CGFloat((value & 0x00FF00) >> 8) / 255,
            blue: CGFloat(value & 0x0000FF) / 255,
            alpha: 1
        )
    }
}
