import SwiftUI
import UIKit

/// Tonal container colour pair used to tell people apart; adapts to light and dark mode.
struct ParticipantAccent {
    let container: Color
    let onContainer: Color
}

/// The same eight accents as Total Scoreboard, so the two apps feel related.
enum ParticipantPalette {
    static let accents: [ParticipantAccent] = [
        accent(light: (0xDEE0FF, 0x000F5D), dark: (0x293CA0, 0xDEE0FF)), // indigo
        accent(light: (0xFFDAD6, 0x410002), dark: (0x93000A, 0xFFDAD6)), // red
        accent(light: (0xC4EED0, 0x002110), dark: (0x1E5130, 0xC4EED0)), // green
        accent(light: (0xFFDEA6, 0x261A00), dark: (0x5C4300, 0xFFDEA6)), // amber
        accent(light: (0xD3E4FF, 0x001C3B), dark: (0x004A77, 0xD3E4FF)), // blue
        accent(light: (0xFFD7F1, 0x2D1228), dark: (0x5D3C55, 0xFFD7F1)), // pink
        accent(light: (0xA6F2EC, 0x00201E), dark: (0x004F4C, 0xA6F2EC)), // teal
        accent(light: (0xEADDFF, 0x21005D), dark: (0x4F378B, 0xEADDFF)), // purple
    ]

    static var count: Int { accents.count }

    static func accent(for index: Int) -> ParticipantAccent {
        accents[((index % count) + count) % count]
    }

    private static func accent(light: (UInt32, UInt32), dark: (UInt32, UInt32)) -> ParticipantAccent {
        ParticipantAccent(
            container: Color(light: light.0, dark: dark.0),
            onContainer: Color(light: light.1, dark: dark.1)
        )
    }
}

extension Color {
    /// A colour that follows the current light/dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
