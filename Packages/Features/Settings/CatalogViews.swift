import Core
import DesignSystem
import SwiftUI

/// Gestione delle categorie (§ 8.6): divise per tipo, con aggiunta, modifica, ordine e archiviazione.
struct CategoriesView: View {
    private struct NewCategory: Identifiable {
        let kind: OperationKind
        var id: OperationKind { kind }
    }

    let repository: any CategoryRepository
    @State private var categories: [OperationCategory] = []
    @State private var editing: OperationCategory?
    @State private var creating: NewCategory?
    @State private var errorMessage: String?

    var body: some View {
        List {
            section("Uscite", kind: .expense)
            section("Entrate", kind: .income)
            let archived = categories.filter(\.isArchived)
            if !archived.isEmpty {
                Section("Archiviate") {
                    ForEach(archived) { category in
                        row(category)
                            .swipeActions {
                                Button("Ripristina") { perform { try await repository.setArchived(category.id, isArchived: false) } }
                            }
                            .contextMenu {
                                Button("Ripristina") { perform { try await repository.setArchived(category.id, isArchived: false) } }
                            }
                    }
                }
            }
        }
        .navigationTitle("Categorie")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        #endif
        .sheet(item: $editing) { category in
            CategoryEditor(name: category.name, symbol: category.symbol, color: category.color) { name, symbol, color in
                try await repository.update(category.id, name: name, symbol: symbol, color: color)
            }
        }
        .sheet(item: $creating) { new in
            CategoryEditor(name: "", symbol: "tag", color: .blue) { name, symbol, color in
                try await repository.create(name: name, kind: new.kind, symbol: symbol, color: color)
            }
        }
        .catalogErrorAlert($errorMessage)
        .task {
            do {
                for try await value in repository.observeCategories(includingArchived: true) {
                    categories = value
                }
            } catch {
                errorMessage = "Non è stato possibile caricare le categorie."
            }
        }
    }

    private func section(_ title: LocalizedStringKey, kind: OperationKind) -> some View {
        let items = categories.filter { $0.kind == kind && !$0.isArchived }
        return Section(title) {
            ForEach(items) { category in
                Button {
                    editing = category
                } label: {
                    row(category)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Rimuovi", role: .destructive) { remove(category) }
                }
                .contextMenu {
                    Button("Modifica") { editing = category }
                    Button("Rimuovi", role: .destructive) { remove(category) }
                }
            }
            .onMove { source, destination in
                var ids = items.map(\.id)
                ids.move(fromOffsets: source, toOffset: destination)
                perform { try await repository.reorder(ids) }
            }
            Button("Aggiungi", systemImage: "plus") { creating = NewCategory(kind: kind) }
        }
    }

    private func row(_ category: OperationCategory) -> some View {
        HStack(spacing: 12) {
            CategoryIcon(symbol: category.symbol, color: category.color)
            Text(category.name)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    /// Con operazioni collegate la categoria viene archiviata e passa nella sezione apposita.
    private func remove(_ category: OperationCategory) {
        perform { _ = try await repository.remove(category.id) }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                errorMessage = "Operazione non riuscita."
            }
        }
    }
}

/// Gestione dei conti (§ 8.6).
struct AccountsView: View {
    private enum Editing: Identifiable {
        case new
        case existing(Account)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let account): account.id.rawValue.uuidString
            }
        }
    }

    let repository: any AccountRepository
    let currency: String
    @State private var accounts: [Account] = []
    @State private var editing: Editing?
    @State private var errorMessage: String?

    var body: some View {
        List {
            let active = accounts.filter { !$0.isArchived }
            Section {
                ForEach(active) { account in
                    Button {
                        editing = .existing(account)
                    } label: {
                        row(account)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Rimuovi", role: .destructive) { remove(account) }
                    }
                    .contextMenu {
                        Button("Modifica") { editing = .existing(account) }
                        Button("Rimuovi", role: .destructive) { remove(account) }
                    }
                }
                .onMove { source, destination in
                    var ids = active.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    perform { try await repository.reorder(ids) }
                }
                Button("Aggiungi", systemImage: "plus") { editing = .new }
            }
            let archived = accounts.filter(\.isArchived)
            if !archived.isEmpty {
                Section("Archiviati") {
                    ForEach(archived) { account in
                        row(account)
                            .swipeActions {
                                Button("Ripristina") { perform { try await repository.setArchived(account.id, isArchived: false) } }
                            }
                            .contextMenu {
                                Button("Ripristina") { perform { try await repository.setArchived(account.id, isArchived: false) } }
                            }
                    }
                }
            }
        }
        .navigationTitle("Conti")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        #endif
        .sheet(item: $editing) { editing in
            switch editing {
            case .new:
                AccountEditor(name: "", initialBalance: 0, currency: currency) { name, balance in
                    try await repository.create(name: name, currency: currency, initialBalance: balance)
                }
            case .existing(let account):
                AccountEditor(name: account.name, initialBalance: account.initialBalance, currency: account.currency) { name, balance in
                    try await repository.update(account.id, name: name, initialBalance: balance)
                }
            }
        }
        .catalogErrorAlert($errorMessage)
        .task {
            do {
                for try await value in repository.observeAccounts(includingArchived: true) {
                    accounts = value
                }
            } catch {
                errorMessage = "Non è stato possibile caricare i conti."
            }
        }
    }

    private func row(_ account: Account) -> some View {
        HStack {
            Text(account.name)
            Spacer()
            Text(MoneyFormat.string(minorUnits: account.initialBalance, currency: account.currency))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityHint("Saldo iniziale")
    }

    private func remove(_ account: Account) {
        perform { _ = try await repository.remove(account.id) }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch RepositoryError.lastActiveAccount {
                errorMessage = "Serve almeno un conto attivo: aggiungine un altro prima di rimuovere questo."
            } catch {
                errorMessage = "Operazione non riuscita."
            }
        }
    }
}

private extension View {
    func catalogErrorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Attenzione",
            isPresented: Binding(get: { message.wrappedValue != nil }, set: { _ in message.wrappedValue = nil }),
            presenting: message.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { text in
            Text(text)
        }
    }
}

// MARK: Editor

private struct CategoryEditor: View {
    /// SF Symbol tra cui scegliere.
    private static let symbols = [
        "tag", "house", "cart", "car", "tram", "airplane", "fuelpump", "fork.knife", "cup.and.saucer",
        "cross.case", "pills", "heart", "gamecontroller", "film", "music.note", "book", "graduationcap",
        "tshirt", "gift", "pawprint", "leaf", "bolt", "drop", "phone", "wifi", "repeat", "wrench.and.screwdriver",
        "banknote", "creditcard", "briefcase", "building.columns", "arrow.uturn.backward.circle", "ellipsis.circle",
    ]

    @State var name: String
    @State var symbol: String
    @State var color: CategoryColor
    let onSave: @MainActor (String, String, CategoryColor) async throws -> Void
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EditorForm(title: "Categoria", canSave: !trimmedName.isEmpty, saveFailed: saveFailed, onSave: save) {
            Section {
                HStack(spacing: 12) {
                    CategoryIcon(symbol: symbol, color: color)
                    TextField("Nome", text: $name)
                }
            }
            Section("Colore") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 12) {
                    ForEach(CategoryColor.allCases, id: \.self) { option in
                        Button {
                            color = option
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if color == option {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.rawValue)
                        .accessibilityAddTraits(color == option ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Icona") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                    ForEach(Self.symbols, id: \.self) { option in
                        Button {
                            symbol = option
                        } label: {
                            Image(systemName: option)
                                .font(.title3)
                                .frame(width: 40, height: 40)
                                .background(
                                    symbol == option ? color.color.opacity(0.25) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option)
                        .accessibilityAddTraits(symbol == option ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        Task {
            do {
                try await onSave(trimmedName, symbol, color)
                dismiss()
            } catch {
                saveFailed = true
            }
        }
    }
}

private struct AccountEditor: View {
    @State var name: String
    @State private var balanceText: String
    let currency: String
    let onSave: @MainActor (String, Int64) async throws -> Void
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss

    init(
        name: String,
        initialBalance: Int64,
        currency: String,
        onSave: @escaping @MainActor (String, Int64) async throws -> Void
    ) {
        _name = State(initialValue: name)
        _balanceText = State(initialValue: AmountInput.text(minorUnits: initialBalance))
        self.currency = currency
        self.onSave = onSave
    }

    var body: some View {
        EditorForm(title: "Conto", canSave: canSave, saveFailed: saveFailed, onSave: save) {
            Section {
                TextField("Nome", text: $name)
            }
            Section("Saldo iniziale in \(currency)") {
                TextField("Saldo iniziale", text: $balanceText)
                    .monospacedDigit()
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Il saldo iniziale può essere negativo (§ 6.2).
    private var balance: Int64? {
        let text = balanceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("-") {
            return AmountInput.minorUnits(from: String(text.dropFirst())).map { -$0 }
        }
        return AmountInput.minorUnits(from: text)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && balance != nil
    }

    private func save() {
        guard let balance else { return }
        Task {
            do {
                try await onSave(trimmedName, balance)
                dismiss()
            } catch {
                saveFailed = true
            }
        }
    }
}

private struct EditorForm<Content: View>: View {
    let title: LocalizedStringKey
    let canSave: Bool
    let saveFailed: Bool
    let onSave: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                content
                if saveFailed {
                    Text("Salvataggio non riuscito. Riprova.")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva", action: onSave)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }
}
