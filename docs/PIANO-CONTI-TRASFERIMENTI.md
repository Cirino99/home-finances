# Piano di sviluppo — Conti e trasferimenti

> Funzionalità nuova, dopo la v1. Le specifiche di riferimento sono in [SPECIFICHE.md](SPECIFICHE.md): i rimandi `§` puntano lì.
> Versione 1.0 — 7 novembre 2026: tutte le decisioni del § 4 sono confermate.
> Stato — 8 novembre 2026: sviluppo completato, step 0–7 (§ 3.3).

---

## 1. Obiettivo

Con più conti serve poter spostare liquidità dall'uno all'altro e vedere quanto c'è su ciascuno. In sintesi:

- **Trasferimento:** nuovo tipo di movimento, da un conto a un altro. Non è né un'entrata né un'uscita.
- **Tab "Conti":** terza sezione accanto a Home e Storico, con il saldo totale, il saldo di ogni conto, il pulsante per trasferire e, per ogni conto, le ultime movimentazioni.
- **Storico filtrato per conto:** da un conto si apre lo Storico già filtrato. Il filtro per conto mostra anche i trasferimenti in entrata e in uscita.

I trasferimenti tra conti erano tra gli sviluppi futuri (§ 13). Questo piano li porta dentro.

---

## 2. Decisioni di progetto

### 2.1 Modello dati: tabella `transfer` separata

| Opzione | Come | Pro | Contro |
|---|---|---|---|
| **A — tabella `transfer` (scelta)** | Una riga per trasferimento, con conto di origine e di destinazione | Nessuna categoria finta. Entrate, uscite, grafici e Home restano esattamente come sono. Un trasferimento si modifica e si elimina in un colpo solo | Lo Storico deve unire due tabelle (`UNION ALL`) e mostrare due tipi di riga |
| B — `kind = 'transfer'` in `operation` | Nuovo tipo nella tabella esistente, con una colonna `to_account_id` | Una sola tabella | `category_id` è `NOT NULL` e il `CHECK` su `kind` non si modifica in SQLite: serve ricostruire la tabella. Ogni query sugli aggregati deve escludere i trasferimenti |
| C — due operazioni collegate | Un'uscita sul conto di origine e un'entrata su quello di destinazione, con una categoria di sistema "Trasferimento" | Il saldo dei conti viene da sé | Entrate e uscite del mese risulterebbero gonfiate, a meno di escluderle ovunque. Le due righe vanno tenute allineate a ogni modifica. Una categoria che l'utente non deve toccare |

Con l'Opzione A, lo schema diventa:

```sql
-- Migrazione v2. La v1 non si tocca (§ 6.2).
CREATE TABLE transfer (
    id               TEXT PRIMARY KEY NOT NULL,
    amount           INTEGER NOT NULL CHECK (amount > 0),
    currency         TEXT NOT NULL,
    date             TEXT NOT NULL,                  -- YYYY-MM-DD
    from_account_id  TEXT NOT NULL REFERENCES account(id) ON DELETE RESTRICT,
    to_account_id    TEXT NOT NULL REFERENCES account(id) ON DELETE RESTRICT,
    note             TEXT,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL,
    CHECK (from_account_id <> to_account_id)
);

CREATE INDEX idx_transfer_date ON transfer(date DESC, created_at DESC);
CREATE INDEX idx_transfer_from ON transfer(from_account_id);
CREATE INDEX idx_transfer_to   ON transfer(to_account_id);
```

- Valgono le convenzioni del § 6.1: UUID come `TEXT`, importo positivo in unità minori, data di calendario gregoriana, timestamp ISO 8601 UTC.
- Ogni scrittura aggiorna `last_modified_at` e `last_modified_by` nella stessa transazione, come per le altre tabelle.
- La valuta è quella del conto di origine. In v1 c'è una sola valuta, quindi coincide con quella di destinazione: il repository lo verifica comunque.

### 2.2 Regole di calcolo

- **Saldo di un conto** = `initial_balance` + entrate − uscite + trasferimenti ricevuti − trasferimenti inviati.
- **Saldo totale** = somma dei saldi di tutti i conti, archiviati compresi: i soldi su un conto archiviato esistono ancora.
- **Entrate, uscite e saldo del mese** (Home, Storico › Mesi e Anni, grafici): **i trasferimenti non contano**. Spostare soldi tra i propri conti non è né guadagnare né spendere.
- **Data dei movimenti nel saldo:** contano tutti, anche quelli con data futura, perché l'editor non mette limiti alla data (§ 8.5).

### 2.3 Come si mostra un trasferimento

- Simbolo `arrow.left.arrow.right` su sfondo di un colore proprio, un nuovo token `transfer` del DesignSystem (blu/indaco), distinto da `income` ed `expense`.
- Titolo della riga: "Conto A → Conto B". Sotto, la nota se c'è.
- **Segno dell'importo:**
  - senza filtro per conto: nessun segno e colore neutro, perché per il totale non cambia nulla;
  - con il filtro su un conto, o nel dettaglio di un conto: "−" se esce da quel conto, "+" se ci entra. Il segno è sempre presente, come chiede il § 9.
- VoiceOver: "Trasferimento, 200 euro, da Conto principale a Risparmi, oggi".

### 2.4 Navigazione

```
TabView (.sidebarAdaptable)
├── Home     (house)
├── Storico  (list.bullet.rectangle)
└── Conti    (building.columns)        ← nuovo
     ├── Card: Saldo totale
     ├── Elenco conti attivi con saldo → Dettaglio conto
     │      ├── Saldo del conto
     │      ├── Ultime 5 movimentazioni → Dettaglio operazione / trasferimento
     │      ├── "Vedi tutte nello Storico" → Storico › Operazioni filtrato sul conto
     │      └── Toolbar: Trasferisci (origine = questo conto)
     ├── Conti archiviati con saldo diverso da zero (sezione a parte, comprimibile)
     └── Toolbar: Trasferisci · Gestisci conti
```

- **Posizione del tab:** Home · Storico · Conti, così ⌘1 e ⌘2 restano come sono e Conti diventa ⌘3.
- **Pulsante "Trasferisci":** nella toolbar del tab Conti e del dettaglio di un conto. Nel tab Home e nello Storico il "+" resta per le operazioni.
- Su Mac anche **File › Nuovo trasferimento** con **⇧⌘N**.
- Con un solo conto attivo il pulsante "Trasferisci" resta visibile ma apre un avviso: "Per trasferire servono almeno due conti", con il pulsante "Aggiungi un conto".
- **Gestisci conti** apre la stessa schermata delle Impostazioni (§ 8.6), che resta anche lì.
- **Layout per piattaforma:** come lo Storico (§ 7.3). iPhone: stack. iPad: `NavigationSplitView` con l'elenco dei conti a sinistra e il dettaglio a destra. Mac: due colonne affiancate e ridimensionabili.

### 2.5 Router

- `AppTab` aggiunge `.accounts`.
- `EditorRequest` aggiunge `.newTransfer(from: AccountID?)` e `.editTransfer(TransferID)`. Lo sheet resta uno solo, presentato dalla radice: a seconda della richiesta mostra l'editor di operazione o quello di trasferimento.
- `HistoryRoute` aggiunge `.transfer(TransferID)`. `homePath` passa da `[OperationID]` a un percorso di route, così dalla Home si apre anche il dettaglio di un trasferimento.
- `accountsPath: [AccountsRoute]` per il nuovo tab, con `AccountsRoute` = `.account(AccountID)`, `.operation(OperationID)`, `.transfer(TransferID)`.
- `showHistory(account:)`: seleziona lo Storico, segmento Operazioni, percorso vuoto, e imposta il filtro per conto. Il filtro passa dal router, che oggi non lo conosce: il modello dell'elenco lo legge all'apertura e poi lo gestisce come gli altri filtri.
- **Conflitto di nomi:** esiste già `TransferRequest`, che indica export e import del database (§ 10). Per non confonderlo con i trasferimenti tra conti viene rinominato `DataTransferRequest`, e `transferRequest` diventa `dataTransferRequest`. Il tipo nuovo si chiama `AccountTransfer`.

### 2.6 Editor di trasferimento

Sheet con `NavigationStack` e `Form`, come l'editor di operazione (§ 8.5). Titolo "Nuovo trasferimento" / "Modifica trasferimento".

| Campo | Controllo | Default | Validazione |
|---|---|---|---|
| Importo | Campo grande, come nell'editor di operazione | Vuoto | > 0, al massimo 2 decimali |
| Da | `Picker` dei conti attivi, con il saldo accanto al nome | Il conto da cui si è partiti, altrimenti il primo | Obbligatorio |
| A | `Picker` dei conti attivi, escluso quello di origine | Il primo conto diverso dall'origine | Obbligatorio, diverso da "Da" |
| Data | `DatePicker` (solo data) | Oggi | Nessun limite |
| Nota | `TextField` multilinea | Vuota | Facoltativa, massimo 200 caratteri |

- Tasto "Inverti" (`arrow.up.arrow.down`) tra Da e A.
- Se l'importo supera il saldo del conto di origine compare un avviso, ma il salvataggio resta possibile: il saldo può andare sotto zero, come già succede con le uscite.
- In modifica, un conto archiviato già usato dal trasferimento resta selezionato e visibile. Per i trasferimenti nuovi si scelgono solo conti attivi.
- Stesso comportamento dell'editor di operazione per Annulla, modifiche non salvate, ⏎ ed ⎋, feedback aptico.

### 2.7 Storico

- **Segmento Operazioni:** l'elenco unisce operazioni e trasferimenti, nello stesso ordine (`date DESC, created_at DESC, id DESC`) e con la stessa paginazione.
- **Filtri:**
  - Tipo: Tutte · Entrate · Uscite · **Trasferimenti**;
  - Categoria: se è scelta, i trasferimenti non compaiono, perché non hanno categoria;
  - **Conto:** c'è già nel menu, ma oggi compare solo con più di un conto. Mostra i trasferimenti in cui il conto è origine o destinazione, con il segno relativo a quel conto (§ 2.3). Il filtro attivo si vede anche fuori dal menu, con un'etichetta "Conto: Risparmi" che si chiude con una ×.
- **Ricerca:** sulla nota e sul nome dei conti del trasferimento.
- **Mesi e Anni:** totali e grafici non cambiano. "Operazioni del mese" mostra anche i trasferimenti del mese, ma il riepilogo in testa resta quello di entrate e uscite.
- Swipe, menu contestuale ed ⌫ funzionano anche sui trasferimenti.
- **Dettaglio trasferimento:** importo, "Da" e "A" con i nomi dei conti, data estesa, nota, date di creazione e di modifica. Toolbar: Modifica · Elimina.

### 2.8 Home

- Il riepilogo del mese non cambia: niente trasferimenti.
- **Ultime operazioni:** comprendono anche i trasferimenti, così la Home mostra davvero l'ultimo movimento registrato. Senza segno, come nello Storico non filtrato.

### 2.9 Conti archiviati e cancellazione

- Un conto con operazioni **o trasferimenti** collegati si archivia invece di cancellarsi. Oggi il controllo guarda solo `operation`: va esteso a `transfer`.
- Rimuovere un conto con saldo diverso da zero, che venga cancellato o archiviato, mostra prima un avviso: "Su questo conto restano 120,00 €. Prima di rimuoverlo puoi trasferirli su un altro conto." con i pulsanti "Trasferisci" e "Rimuovi comunque". L'editor si apre sopra la schermata dei conti, perché su Mac le Impostazioni sono una finestra a parte.

### 2.10 Export, import e CSV

- **File `.homefinances`:** contiene anche la tabella `transfer`.
  - Un file creato dalla versione precedente (solo migrazione `v1`) resta importabile: dopo l'import si esegue la `v2`.
  - Un file con la `v2` aperto da un'app che ha solo la `v1` viene rifiutato come "versione più recente", come già previsto (§ 10.4).
  - La validazione controlla anche le righe di `transfer` e la regola origine ≠ destinazione.
- **Schermata di confronto dell'import:** il conteggio "Operazioni" diventa "Movimenti", operazioni più trasferimenti. Anche "Operazione più recente" guarda entrambe le tabelle.
- **CSV:** una riga per trasferimento, con `tipo` = "Trasferimento", `categoria` vuota e `conto` = "Conto A → Conto B".

### 2.11 Fuori scope

- Trasferimenti tra conti con valute diverse, perché in v1 la valuta è una sola.
- Trasferimenti ricorrenti.
- Trasferimenti verso conti esterni: quelli restano uscite o entrate.

---

## 3. Piano di sviluppo

Ogni step si chiude con il codice che compila e i test che passano. Compilazione e test li esegui tu. Dopo la tua conferma ti propongo il commit, poi si passa allo step successivo.

| Step | Contenuto | File principali | Uscita |
|---|---|---|---|
| **0** | Decisioni confermate. Aggiornamento di `SPECIFICHE.md` alla 1.16: § 6, § 7, § 8, § 10, § 13 | `docs/` | Specifiche allineate |
| **1** | **Core.** `AccountTransfer`, `TransferID`, `TransferDraft` con le regole di validazione. `AccountBalance`. Elemento di elenco comune `MovementListItem` (operazione o trasferimento). `MovementQuery` e `MovementKind`. Nuovi protocolli `TransferRepository` e `MovementRepository` (movimenti e saldi). CSV con i trasferimenti. Rinomina di `TransferRequest` in `DataTransferRequest`. Filtro per conto nel router (`showHistory(account:)`) | nuovo `Core/Transfers.swift`, `Core/Repositories.swift`, `Core/AppRouter.swift`, `Core/DataTransfer.swift` + test in `CoreTests` | Il modello di dominio compila, test delle regole |
| **2** | **Persistence.** Migrazione `v2` con la tabella `transfer`. `GRDBTransferRepository`: crea, modifica, elimina, osserva. Saldi per conto e totale con `ValueObservation`. Elenco dei movimenti con `UNION ALL`, filtri, ricerca e pagine. Archiviazione dei conti che considera i trasferimenti. Inspector, riepilogo dell'import e CSV con i trasferimenti | `Persistence/AppDatabase.swift`, nuovo `Persistence/TransferRepository.swift`, `OperationRepository.swift`, `CatalogRepositories.swift`, `DatabaseInspector.swift`, `RowMapping.swift`, `DatabaseStore.swift` + test in `PersistenceTests` | Strato dati completo e testato, compresi migrazione da v1, import di un file v1 e saldi |
| **3** | **Editor e dettaglio del trasferimento.** Modello `@Observable` e vista dell'editor, dettaglio con Modifica ed Elimina. Richieste `.newTransfer` ed `.editTransfer` nel router, gestite dallo sheet della radice. ⇧⌘N su Mac | `Features/OperationEditor/` (nuovi `TransferEditor*.swift`, `TransferDetailView.swift`), `HomeFinances/RootTabView.swift`, `HomeFinancesApp.swift`, `DesignSystem/Colors.swift` + test in `OperationEditorFeatureTests` | Si crea, si modifica e si elimina un trasferimento |
| **4** | **Storico.** Righe dei trasferimenti nell'elenco, filtro "Trasferimenti", filtro per conto con il segno relativo e l'etichetta visibile, ricerca sui nomi dei conti, route `.transfer` nel router, filtro impostato dal router | `Features/History/`, `DesignSystem/OperationRow.swift` (riga del trasferimento) + test in `HistoryFeatureTests` | Lo Storico mostra e filtra tutti i movimenti |
| **5** | **Tab Conti.** Nuovo modulo `AccountsFeature`: saldo totale, elenco dei conti con saldo, conti archiviati, dettaglio del conto con le ultime 5 movimentazioni, "Vedi tutte nello Storico", "Trasferisci", "Gestisci conti". `AppTab.accounts`, `accountsPath` e `AccountsRoute` nel router. Layout per iPhone, iPad e Mac. ⌘3 | nuovo `Features/Accounts/`, `Package.swift`, `RootTabView.swift`, `HomeFinancesApp.swift` + nuovo `AccountsFeatureTests` | Terza sezione completa |
| **6** | **Home e conti archiviati.** Trasferimenti tra le ultime operazioni, `homePath` con le route. Avviso quando si archivia un conto con saldo | `Features/Home/`, `Features/Settings/CatalogViews.swift` + test in `HomeFeatureTests` | Home coerente con i nuovi movimenti |
| **7** | **Rifinitura.** VoiceOver e Dynamic Type sulle nuove schermate, testi nel catalogo, prove manuali su iPhone, iPad e Mac, aggiornamento del README | tutte le nuove viste, `Localizable.xcstrings`, `README.md` | Funzionalità pronta |

### 3.1 Dipendenze tra gli step

- Lo step 1 viene prima di tutto, e lo step 2 prima delle feature.
- Dopo lo step 2, gli step 3, 4 e 5 toccano moduli diversi. Ogni step aggiunge al router solo le route che usa, così dopo ogni step il progetto compila: una route senza la vista che la mostra renderebbe incompleti gli `switch` delle feature. Il 5 apre l'editor del 3, quindi conviene farli in ordine.
- Lo step 6 viene dopo il 3 e il 4, perché riusa le righe e il dettaglio dei trasferimenti.

### 3.2 Test previsti

**Unit test:**
- `TransferDraft`: importo > 0, conti diversi, nota di 200 caratteri al massimo.
- Saldi: conto senza movimenti, solo saldo iniziale negativo, entrate e uscite, trasferimenti in entrata e in uscita, conti archiviati nel totale.
- Totali del mese, dei mesi e degli anni identici prima e dopo l'aggiunta di trasferimenti.
- Elenco dei movimenti: ordine stabile tra operazioni e trasferimenti dello stesso giorno, pagine senza duplicati né buchi, filtro per tipo, per conto in entrambe le direzioni, categoria che esclude i trasferimenti, ricerca sui nomi dei conti.
- Vincoli: origine uguale a destinazione rifiutata, conto inesistente, `RESTRICT` sulla cancellazione di un conto usato da un trasferimento.
- Archiviazione: conto usato solo da trasferimenti archiviato e non cancellato.

**Test di integrazione:**
- Migrazione di un database `v1` con dati: tutto resta, la tabella `transfer` è vuota.
- Export → import con trasferimenti: dati identici.
- Import di un file `v1` su un'app `v2`: accettato e migrato.
- File con un trasferimento da un conto a sé stesso: rifiutato.
- CSV con i trasferimenti.

**Prove manuali:**
- Trasferimento dal tab Conti → saldi aggiornati in entrambi i conti → presente nello Storico → filtro per conto con il segno giusto.
- "Vedi tutte nello Storico" dal dettaglio di un conto → Storico già filtrato → togliendo il filtro compare tutto.
- Archiviazione di un conto con saldo.
- iPhone, iPad (regolare e Split View) e Mac (finestra al minimo) per il tab Conti.

---

### 3.3 Stato

| Step | Commit | Note |
|---|---|---|
| 0 | `e90bcb0` | |
| 1 | `10afa87` | Le route del router arrivano con gli step che le usano |
| 2 | `88ee4d7` | Lo schema di un file importato si confronta con quello della stessa versione, non solo dell'ultima |
| 3 | `e82ce0e` | Campo importo condiviso nel DesignSystem |
| 4 | `550abf5` | |
| 5 | `93209c6` | Gestisci conti apre la schermata delle Impostazioni, presentata dalla radice. Niente "Trasferisci" sui conti archiviati |
| 6 | `850dea9` | L'avviso vale per qualsiasi rimozione, non solo per l'archiviazione. Gestisci conti mostra il saldo attuale. Un solo "Trasferisci" con elenco e dettaglio affiancati |
| 7 | — | VoiceOver e Dynamic Type sulle righe dei conti e nell'editor, test e prove manuali nelle specifiche (§ 11), README. Dalla revisione del codice: copertura nello switcher anche per gli sheet annidati, sezione Archiviati apribile su iPhone, ricerca per conto anche sulle operazioni, saldo letto al momento della rimozione, navigazione comune a Storico e Conti nel DesignSystem |

## 4. Decisioni

Tutte confermate il 7 novembre 2026.

| # | Decisione | Scelta |
|---|---|---|
| 1 | Modello dati dei trasferimenti (§ 2.1) | Tabella `transfer` separata (Opzione A) |
| 2 | Saldo totale con i conti archiviati (§ 2.2) | Sì, li comprende |
| 3 | Movimenti con data futura nel saldo (§ 2.2) | Contano tutti |
| 4 | Posizione del tab Conti (§ 2.4) | Home · Storico · Conti, con ⌘3 |
| 5 | Dove si avvia un trasferimento (§ 2.4) | Pulsante "Trasferisci" nel tab Conti e nel dettaglio di un conto; il "+" resta per le operazioni |
| 6 | Importo oltre il saldo dell'origine (§ 2.6) | Avviso, ma salvataggio consentito |
| 7 | Etichetta del filtro per conto fuori dal menu (§ 2.7) | Sì |
| 8 | Trasferimenti tra le ultime operazioni della Home (§ 2.8) | Sì |
| 9 | Conteggio nella schermata di confronto dell'import (§ 2.10) | "Movimenti" = operazioni + trasferimenti |
| 10 | Trasferimenti nel CSV (§ 2.10) | Una riga, con "Conto A → Conto B" |
