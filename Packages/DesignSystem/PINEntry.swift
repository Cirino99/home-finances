import SwiftUI

/// Inserimento di un PIN numerico: pallini, tastierino e tastiera fisica (§ 8.1).
///
/// `onComplete` riceve il PIN quando sono state inserite tutte le cifre; svuotare `pin` spetta a chi lo usa.
/// Incrementare `failureCount` fa scuotere i pallini con feedback aptico di errore.
public struct PINEntryView<Accessory: View>: View {
    private let length: Int
    @Binding private var pin: String
    private let isEnabled: Bool
    private let failureCount: Int
    private let onComplete: (String) -> Void
    private let accessory: Accessory
    @FocusState private var isFocused: Bool

    public init(
        length: Int = 6,
        pin: Binding<String>,
        isEnabled: Bool = true,
        failureCount: Int = 0,
        onComplete: @escaping (String) -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.length = length
        _pin = pin
        self.isEnabled = isEnabled
        self.failureCount = failureCount
        self.onComplete = onComplete
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(spacing: 40) {
            PINDots(length: length, filled: pin.count)
                .keyframeAnimator(initialValue: 0.0, trigger: failureCount) { dots, offset in
                    dots.offset(x: offset)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(-14.0, duration: 0.06)
                        LinearKeyframe(12.0, duration: 0.06)
                        LinearKeyframe(-10.0, duration: 0.06)
                        LinearKeyframe(8.0, duration: 0.06)
                        LinearKeyframe(-4.0, duration: 0.06)
                        LinearKeyframe(0.0, duration: 0.06)
                    }
                }
                .sensoryFeedback(.error, trigger: failureCount)

            PINKeypad(
                isEnabled: isEnabled,
                canDelete: !pin.isEmpty,
                onDigit: append,
                onDelete: deleteLast,
                accessory: accessory
            )
        }
        // Sempre attivabile: se il focus si perdesse durante la verifica, la tastiera fisica smetterebbe di funzionare.
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard isEnabled else { return .ignored }
            if press.key == .delete {
                deleteLast()
                return .handled
            }
            guard let character = press.characters.first, character.isASCII, character.isWholeNumber else {
                return .ignored
            }
            append(character)
            return .handled
        }
        .onAppear { isFocused = true }
    }

    private func append(_ digit: Character) {
        guard isEnabled, pin.count < length else { return }
        // Il valore si calcola prima di scriverlo: dentro `onKeyPress` il binding può restituire ancora quello vecchio.
        let updated = pin + String(digit)
        pin = updated
        if updated.count == length {
            onComplete(updated)
        }
    }

    private func deleteLast() {
        guard isEnabled, !pin.isEmpty else { return }
        pin.removeLast()
    }
}

public extension PINEntryView where Accessory == EmptyView {
    init(
        length: Int = 6,
        pin: Binding<String>,
        isEnabled: Bool = true,
        failureCount: Int = 0,
        onComplete: @escaping (String) -> Void
    ) {
        self.init(length: length, pin: pin, isEnabled: isEnabled, failureCount: failureCount, onComplete: onComplete) {
            EmptyView()
        }
    }
}

public extension View {
    /// Scorre solo se non ci sta, ad esempio con le dimensioni di testo per l'accessibilità.
    func scrollsIfNeeded() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView { self }
        }
    }
}

struct PINDots: View {
    let length: Int
    let filled: Int

    var body: some View {
        HStack(spacing: 18) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .fill(index < filled ? Color.primary : Color.clear)
                    .stroke(Color.primary, lineWidth: 1.5)
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("PIN")
        .accessibilityValue("\(filled) cifre su \(length)")
    }
}

struct PINKeypad<Accessory: View>: View {
    let isEnabled: Bool
    let canDelete: Bool
    let onDigit: (Character) -> Void
    let onDelete: () -> Void
    let accessory: Accessory

    @ScaledMetric(relativeTo: .title) private var scaledKeySize: CGFloat = 76
    private let rows: [[Character]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    /// Cresce col testo, ma oltre questo limite il tastierino non starebbe nella larghezza di un iPhone.
    private var keySize: CGFloat {
        min(scaledKeySize, 96)
    }

    var body: some View {
        Grid(horizontalSpacing: 24, verticalSpacing: 16) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self, content: digitKey)
                }
            }
            GridRow {
                accessory
                    .frame(width: keySize, height: keySize)
                digitKey("0")
                Button(action: onDelete) {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .frame(width: keySize, height: keySize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled || !canDelete)
                .opacity(canDelete ? 1 : 0)
                .accessibilityLabel("Cancella")
            }
        }
    }

    private func digitKey(_ digit: Character) -> some View {
        Button {
            onDigit(digit)
        } label: {
            Text(String(digit))
                .font(.title)
                .monospacedDigit()
                .frame(width: keySize, height: keySize)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

#Preview {
    @Previewable @State var pin = "12"
    PINEntryView(pin: $pin, onComplete: { _ in })
}
