import SwiftUI

public extension EnvironmentValues {
    /// L'app è nello switcher, o sta per andarci: i dati vanno coperti (§ 9).
    @Entry var isPrivacyCovered = false
}

public extension View {
    /// Copre il contenuto nello switcher app (§ 9). Da applicare anche agli sheet, che restano sopra la radice.
    /// Passa lo stato anche nell'ambiente: gli sheet aperti dal contenuto lo leggono con `inheritedPrivacyCover()`.
    func privacyCover(_ isCovered: Bool) -> some View {
        overlay {
            if isCovered {
                PrivacyCoverView()
            }
        }
        .environment(\.isPrivacyCovered, isCovered)
    }

    /// Per uno sheet aperto da una vista già coperta: un nuovo sheet sta sopra la copertura di chi lo apre,
    /// quindi deve coprirsi da sé. Lo stato arriva dall'ambiente, che gli sheet ereditano.
    func inheritedPrivacyCover() -> some View {
        modifier(InheritedPrivacyCover())
    }
}

private struct InheritedPrivacyCover: ViewModifier {
    @Environment(\.isPrivacyCovered) private var isCovered

    func body(content: Content) -> some View {
        content.privacyCover(isCovered)
    }
}

private struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            Image(systemName: "lock.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
