import SwiftUI

#if os(macOS)
/// Linea tra lista e dettaglio, da trascinare per cambiare la larghezza della lista.
/// La larghezza scelta resta salvata tra un avvio e l'altro.
public struct ColumnResizeHandle: View {
    @Binding private var width: Double
    private let range: ClosedRange<Double>
    @State private var widthAtDragStart: Double?

    public init(width: Binding<Double>, range: ClosedRange<Double>) {
        _width = width
        self.range = range
    }

    public var body: some View {
        Divider()
            .overlay {
                // Più larga della linea, per afferrarla senza dover essere precisi.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        // Coordinate globali: la linea si sposta con la colonna durante il trascinamento.
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = widthAtDragStart ?? width
                                widthAtDragStart = start
                                width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in
                                widthAtDragStart = nil
                            }
                    )
            }
    }
}
#endif
