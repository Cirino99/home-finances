import AppSecurity
import DesignSystem
import SwiftUI

/// Mostra `content` solo ad app sbloccata; altrimenti onboarding o schermata di blocco (§ 5.4, § 8.1).
///
/// Al blocco il contenuto viene rimosso dalla gerarchia: sheet e alert aperti si chiudono con lui.
/// Lo stato da ritrovare dopo lo sblocco (tab, segmento) vive fuori, nel router e in `@SceneStorage`.
public struct LockGate<Content: View>: View {
    @Bindable private var appLock: AppLock
    private let content: Content

    public init(appLock: AppLock, @ViewBuilder content: () -> Content) {
        _appLock = Bindable(appLock)
        self.content = content()
    }

    public var body: some View {
        Group {
            switch appLock.phase {
            case .unlocked:
                content
                    .privacyCover(appLock.isPrivacyCovered)
                    .alert("\(appLock.biometry.displayName) disattivato", isPresented: $appLock.offersBiometricReenable) {
                        Button("Riattiva") {
                            Task { try? await appLock.enableBiometricUnlock() }
                        }
                        Button("Non ora", role: .cancel) {}
                    } message: {
                        Text("Le biometrie registrate su questo dispositivo sono cambiate: per sicurezza lo sblocco con \(appLock.biometry.displayName) è stato disattivato.")
                    }
            case .locked:
                LockScreen(appLock: appLock)
            case .setup(let reason):
                OnboardingView(appLock: appLock, reason: reason)
            }
        }
        .appLockLifecycle(appLock)
    }
}
