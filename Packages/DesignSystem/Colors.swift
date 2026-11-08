import SwiftUI

/// Token colore del DesignSystem (§ 9), con varianti chiare e scure. Sono usati anche per il testo
/// degli importi: la variante chiara è più scura dei colori di sistema, per un contrasto leggibile sul bianco.
public extension Color {
    static let income = Color(light: (0.10, 0.50, 0.22), dark: (0.19, 0.82, 0.35))
    static let expense = Color(light: (0.78, 0.16, 0.16), dark: (1.00, 0.41, 0.38))
    /// Trasferimenti tra conti: né entrata né uscita (§ 8.8).
    static let transfer = Color(light: (0.29, 0.31, 0.78), dark: (0.55, 0.60, 1.00))
}

private extension Color {
    init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (red, green, blue) = isDark ? dark : light
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let (red, green, blue) = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
        })
        #endif
    }
}
