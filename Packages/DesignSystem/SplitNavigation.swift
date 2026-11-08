import SwiftUI

/// Elenco e dettaglio delle sezioni con un percorso, come Storico e Conti (§ 7.3).
///
/// `path` è l'unica fonte del percorso: su iPhone è lo stack; su iPad e Mac il primo elemento è
/// la riga selezionata nell'elenco e il resto ciò che si apre nel dettaglio.
public struct SplitNavigation<Route: Hashable, Root: View, Destination: View>: View {
    @Binding private var path: [Route]
    private let placeholder: LocalizedStringKey
    private let placeholderSymbol: String
    private let detailTitle: (Route) -> String?
    private let root: (Binding<Route?>?) -> Root
    private let destination: (Route) -> Destination
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    @AppStorage private var listWidth: Double
    private let listWidthRange: ClosedRange<Double>
    #endif

    /// - Parameters:
    ///   - listWidthKey: dove ricordare la larghezza dell'elenco su Mac, tra un avvio e l'altro.
    ///   - detailTitle: titolo della barra sopra il dettaglio su Mac; `nil` per non mostrarla
    ///     quando non c'è nemmeno un livello a cui tornare.
    ///   - root: l'elenco; riceve la selezione nelle colonne affiancate, `nil` nello stack.
    public init(
        path: Binding<[Route]>,
        listWidthKey: String,
        defaultListWidth: Double,
        listWidthRange: ClosedRange<Double>,
        placeholder: LocalizedStringKey,
        placeholderSymbol: String,
        detailTitle: @escaping (Route) -> String?,
        @ViewBuilder root: @escaping (Binding<Route?>?) -> Root,
        @ViewBuilder destination: @escaping (Route) -> Destination
    ) {
        _path = path
        self.placeholder = placeholder
        self.placeholderSymbol = placeholderSymbol
        self.detailTitle = detailTitle
        self.root = root
        self.destination = destination
        #if os(macOS)
        _listWidth = AppStorage(wrappedValue: defaultListWidth, listWidthKey)
        self.listWidthRange = listWidthRange
        #endif
    }

    public var body: some View {
        #if os(macOS)
        // Niente `NavigationSplitView`: annidata nella sidebar dell'app, sposta il dettaglio
        // verso destra lasciando un vuoto a sinistra. Affiancate così, le colonne restano al loro posto.
        HStack(spacing: 0) {
            NavigationStack {
                root(selection)
            }
            .frame(width: listWidth)
            ColumnResizeHandle(width: $listWidth, range: listWidthRange)
            detail
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                root(selection)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
            } detail: {
                detail
            }
        } else {
            NavigationStack(path: $path) {
                root(nil)
                    .navigationDestination(for: Route.self, destination: destination)
            }
        }
        #endif
    }

    private var selection: Binding<Route?> {
        Binding(
            get: { path.first },
            set: { route in path = route.map { [$0] } ?? [] }
        )
    }

    #if os(macOS)
    /// Mostra direttamente l'ultimo elemento del percorso, senza uno stack di navigazione:
    /// con due stack affiancati, aprire un elemento nel dettaglio faceva sparire la lista.
    @ViewBuilder
    private var detail: some View {
        if let route = path.last {
            destination(route)
                .id(route)
                .safeAreaInset(edge: .top, spacing: 0) {
                    detailHeader(route)
                }
        } else {
            ContentUnavailableView(placeholder, systemImage: placeholderSymbol)
        }
    }

    @ViewBuilder
    private func detailHeader(_ route: Route) -> some View {
        let title = detailTitle(route)
        if path.count > 1 || title != nil {
            HStack(spacing: 8) {
                if path.count > 1 {
                    Button("Indietro", systemImage: "chevron.left") {
                        path.removeLast()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut("[", modifiers: .command)
                }
                Text(verbatim: title ?? "")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
    #else
    /// Ciò che si è aperto dentro il dettaglio, oltre alla selezione.
    private var detailPath: Binding<[Route]> {
        Binding(
            get: { Array(path.dropFirst()) },
            set: { newPath in
                if let first = path.first {
                    path = [first] + newPath
                }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let route = path.first {
            NavigationStack(path: detailPath) {
                destination(route)
                    .navigationDestination(for: Route.self, destination: destination)
            }
            .id(route)
        } else {
            ContentUnavailableView(placeholder, systemImage: placeholderSymbol)
        }
    }
    #endif
}

/// Elenco con selezione nella colonna di una split view, senza selezione in uno stack.
public struct SelectableList<Route: Hashable, Content: View>: View {
    private let selection: Binding<Route?>?
    private let content: Content

    public init(selection: Binding<Route?>?, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.content = content()
    }

    public var body: some View {
        if let selection {
            List(selection: selection) { content }
                #if os(macOS)
                // Con lo stile predefinito, su Mac le righe di questi elenchi risultano tagliate.
                .listStyle(.sidebar)
                #endif
                .environment(\.defaultMinListRowHeight, 52)
        } else {
            List { content }
                #if os(macOS)
                .listStyle(.sidebar)
                #endif
                .environment(\.defaultMinListRowHeight, 52)
        }
    }
}

/// Riga che apre `route`: nella colonna con selezione basta il tag. Altrove, su iPhone e iPad è un
/// link dello stack; su Mac il dettaglio non ha uno stack, quindi `open` aggiunge `route` al percorso.
public struct RouteRow<Route: Hashable, Content: View>: View {
    private let route: Route
    private let isSelectable: Bool
    private let open: (Route) -> Void
    private let content: Content

    public init(route: Route, isSelectable: Bool, open: @escaping (Route) -> Void, @ViewBuilder content: () -> Content) {
        self.route = route
        self.isSelectable = isSelectable
        self.open = open
        self.content = content()
    }

    public var body: some View {
        if isSelectable {
            content.tag(route)
        } else {
            #if os(macOS)
            Button {
                open(route)
            } label: {
                HStack {
                    content
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #else
            NavigationLink(value: route) { content }
            #endif
        }
    }
}
