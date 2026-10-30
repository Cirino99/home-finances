# Specifica di progetto — Home Finances

> Repository: `home-finances` · Progetto Xcode: `HomeFinances`

> Documento base per lo sviluppo. Raccoglie le decisioni prese su piattaforme, stack, sicurezza, modello dati, navigazione e schermate.
> Le voci marcate **[DA CONFERMARE]** sono proposte non ancora approvate.
> Versione 1.4 — 30 ottobre 2026
> **Modifiche:**
> - 1.4 — decisa la #3: nessuna cancellazione dei dati dopo N PIN errati in v1. La scelta della valuta nell'onboarding arriva con lo strato dati (Sprint 2). Biometria: `domainState` al posto di `evaluatedPolicyDomainState`, deprecato.
> - 1.1 — la cifratura del database (SQLCipher) è rimandata a una versione futura (§ 13). L'accesso resta protetto da PIN / Face ID.
> - 1.2 — confermati SQLite + GRDB. La sincronizzazione tra dispositivi è **manuale**, tramite export e import del database dall'app (§ 10).
> - 1.3 — nome del progetto: repository `home-finances`, progetto Xcode `HomeFinances`, file di export `.homefinances`.

---

## 1. Obiettivo

App nativa per la gestione delle finanze personali. Registra entrate e uscite, mostra un riepilogo mensile e uno storico consultabile per operazione, mese e anno.

Principi guida:

- **Solo locale.** Nessun server, nessun account, nessun dato in rete.
- **Accesso protetto.** I dati sono visibili solo dopo lo sblocco con PIN o Face ID / Touch ID. La cifratura del file è rimandata (§ 13), ma il codice è predisposto per aggiungerla (§ 5.6).
- **Un solo codice** per iPhone, iPad e Mac, conforme alle Human Interface Guidelines (HIG) Apple per il multipiattaforma.

---

## 2. Piattaforme e requisiti minimi

| Piattaforma | Versione minima | Note |
|---|---|---|
| iOS (iPhone) | **iOS 18** | Necessario per `TabView` con `.sidebarAdaptable` e la nuova API `Tab` |
| iPadOS | **iPadOS 18** | Come sopra |
| macOS | **macOS 15** | App Mac nativa SwiftUI, **non** Mac Catalyst |

- Linguaggio: **Swift 6** con strict concurrency attiva.
- Funzionalità di iOS/iPadOS/macOS 26, come `tabViewBottomAccessory` e Liquid Glass, si usano dietro `if #available(...)`, con un fallback per le versioni 18/15.
- Un unico target Xcode multipiattaforma ("Multiplatform App").

---

## 3. Stack tecnologico

| Livello | Tecnologia | Motivazione |
|---|---|---|
| UI | **SwiftUI** + Observation (`@Observable`) | Codice unico per le tre piattaforme |
| Database | **SQLite** (versione di sistema) | Locale, nessun server, aggregati calcolati in SQL |
| Accesso dati | **GRDB.swift** 7.x tramite Swift Package Manager (pacchetto standard) | Migrazioni, record tipizzati, `ValueObservation` per una UI reattiva |
| Hash del PIN | **CommonCrypto** (PBKDF2-HMAC-SHA256) | Il PIN non viene mai salvato in chiaro |
| Segreti | **Keychain Services** | Conservazione dell'hash del PIN e del contatore dei tentativi |
| Autenticazione | **LocalAuthentication** | Face ID / Touch ID |
| Grafici | **Swift Charts** | Andamenti mensili e annuali nello storico |
| Test | **Swift Testing** + DB GRDB in memoria | Test rapidi e isolati |
| Localizzazione | **String Catalogs** (`.xcstrings`) | Lingua base: italiano |

### Esclusioni motivate

- **SwiftData / Core Data:**
  - non offrono la cifratura del database, che resta un obiettivo futuro;
  - SwiftData non calcola somme e aggregati direttamente in SQL, che sono il cuore di Home e Storico.
- **Dipendenze di terze parti:** solo GRDB. Tutto il resto viene dai framework Apple.

### Alternative valutate e scartate

- **SwiftData:** avrebbe offerto la sincronizzazione iCloud quasi gratis, ma la sincronizzazione sarà manuale. Inoltre renderebbe di fatto impossibile aggiungere la cifratura in futuro e complicherebbe l'export/import del database.
- **SQLiteData (Point-Free):** il suo vantaggio principale è la sincronizzazione CloudKit, che non serve. Si usa GRDB diretto, con una dipendenza in meno.

---

## 4. Architettura del progetto

```
HomeFinances.xcodeproj
├── HomeFinances/               ← target app (sottile: entry point, scene, composizione)
│   ├── HomeFinancesApp.swift
│   ├── AppRoot.swift           ← gestione blocco/sblocco + TabView
│   └── Resources/              ← Assets, Localizable.xcstrings, Info.plist
└── Packages/                   ← Swift Package locale con più target
    ├── Core/                   ← modelli di dominio, regole, formattazione importi (puro Swift)
    ├── Persistence/            ← GRDB, apertura DB centralizzata, migrazioni, repository, query aggregate
    ├── Security/               ← Keychain, PIN, biometria, AppLock
    ├── DesignSystem/           ← componenti UI condivisi (card importo, riga operazione, ecc.)
    └── Features/
        ├── Lock/               ← schermata di blocco
        ├── Home/
        ├── History/            ← Storico
        ├── OperationEditor/    ← Nuova/Modifica operazione
        └── Settings/
```

Regole di dipendenza:

- `Core` non dipende da nulla.
- `Persistence` e `Security` dipendono da `Core`.
- `Features` dipendono da `Core`, `DesignSystem` e dai **protocolli** dei repository, non da GRDB direttamente.
- L'app compone le dipendenze e le inietta tramite `Environment`.

Pattern:

- View SwiftUI + modello `@Observable` per ogni schermata.
- I repository espongono `async` per le scritture e `AsyncSequence`/observation per le letture reattive.
- Nessuna logica di business nelle View.

---

## 5. Sicurezza e accesso

### 5.1 Requisito (v1)

- L'accesso ai dati è protetto da **PIN** o **Face ID / Touch ID**.
- **La cifratura del database è rimandata** (§ 13). In v1 l'app non cifra il file SQLite. Su disco valgono le protezioni di sistema:
  - Data Protection di iOS/iPadOS, con la classe di default;
  - FileVault su macOS, se attivo.

### 5.2 PIN

- **6 cifre**, impostato obbligatoriamente al primo avvio. È il metodo di riserva sempre disponibile.
- **Il PIN non viene mai salvato in chiaro.** Nel Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) si salvano:
  - salt casuale da 16 byte (`SecRandomCopyBytes`);
  - hash PBKDF2-HMAC-SHA256, con almeno 600.000 iterazioni;
  - il numero di iterazioni usato, così si potrà aumentarlo in futuro.
- Verifica: si ricalcola l'hash del PIN inserito e lo si confronta in tempo costante.
- Tentativi errati:

| Tentativi falliti | Effetto |
|---|---|
| 1–4 | Nessun ritardo |
| 5 | Attesa 1 minuto |
| 6 | Attesa 5 minuti |
| 7 | Attesa 15 minuti |
| ≥ 8 | Attesa 1 ora per ogni tentativo |

- Il contatore e il timestamp del blocco sono salvati nel Keychain, così non si azzerano reinstallando o cancellando le preferenze.
- **Nessuna cancellazione automatica dei dati** dopo N tentativi in v1.
- Il tentativo viene contato **prima** del calcolo dell'hash: chiudere l'app durante la verifica non lo annulla.

### 5.3 Biometria

- Opzionale. Si attiva dopo l'impostazione del PIN, con una proposta al primo avvio e un interruttore nelle Impostazioni.
- Sblocco con `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, ...)`.
- **Cambio delle impronte o dei volti registrati:**
  - all'attivazione si salva nel Keychain `LAContext.domainState.biometry.stateHash` (sostituisce `evaluatedPolicyDomainState`, deprecato da iOS 18 / macOS 15);
  - se al login il valore è diverso, la biometria viene disattivata e l'app chiede il PIN, poi propone di riattivarla.
- In Info.plist: `NSFaceIDUsageDescription` = "Usa Face ID per sbloccare i tuoi dati finanziari."

### 5.4 Ciclo di vita del blocco

Il database resta aperto per tutta la sessione. Il blocco agisce sulla **UI**: finché l'app non è sbloccata, nessuna schermata con dati viene mostrata.

| Evento | Azione |
|---|---|
| Avvio app | Schermata di blocco |
| Sblocco riuscito | Rimozione dell'overlay, contenuto visibile |
| iOS/iPadOS: `scenePhase == .inactive` | Overlay di privacy (sfocatura + logo) per nascondere i dati nello switcher app |
| iOS/iPadOS: `scenePhase == .background` | **Blocco immediato**: overlay di blocco e chiusura di sheet e alert aperti |
| macOS: inattività | Blocco dopo **5 minuti** di inattività (configurabile: 1, 5, 15, 30 min) |
| macOS: blocco schermo / stop | Blocco immediato (notifiche `NSWorkspace` / `DistributedNotificationCenter`) |
| macOS: menu | Voce "Blocca" con scorciatoia **⌃⌘L** |

### 5.5 Dati su disco e backup

- **Posizione del file:** `Application Support/<bundle-id>/homefinances.sqlite`, con WAL attivo (`DatabasePool`).
- **iOS/iPadOS:** classe Data Protection di default (`completeUntilFirstUserAuthentication`).
- **Backup di sistema** (iCloud/Finder su iOS, Time Machine su Mac): il database **è incluso** **[DA CONFERMARE]**.
- **Ripristino su un nuovo dispositivo:**
  - l'hash del PIN è `ThisDeviceOnly` e quindi non viene ripristinato;
  - se l'app trova un database ma nessun PIN, chiede di autenticarsi con il codice del dispositivo (`.deviceOwnerAuthentication`), poi fa impostare un nuovo PIN.
- **Export compliance App Store:** senza SQLCipher l'app usa crittografia solo per l'hash del PIN. Con ogni probabilità `ITSAppUsesNonExemptEncryption = NO`, da verificare al momento della pubblicazione.

### 5.6 Predisposizione per la cifratura futura

Per aggiungere SQLCipher in seguito senza riscrivere nulla:

- **Apertura del database centralizzata** in un solo punto (`AppDatabase.open(at:configuration:)` nel modulo `Persistence`). Nessun altro modulo crea connessioni o conosce il percorso del file.
- **Accesso ai dati solo tramite i protocolli dei repository**, mai GRDB direttamente dalle feature.
- **Nessuna funzione SQLite usata in v1 che non sia presente in SQLCipher.** SQLCipher è un fork di SQLite, quindi basta evitare estensioni caricate a runtime.
- **Migrazione prevista:**
  1. al primo avvio della versione con cifratura, si apre il file in chiaro;
  2. si esporta in un nuovo file cifrato con `sqlcipher_export`;
  3. si verifica l'integrità e si sostituisce il file in modo atomico;
  4. si elimina la copia in chiaro.

  Lo schema non cambia.
- **Il PIN potrà diventare la base della chiave**, con la gerarchia di chiavi della versione 1.0 di questo documento. Al primo sblocco dopo l'aggiornamento si migra dall'hash al wrapping della chiave.

---

## 6. Modello dati

### 6.1 Convenzioni

- **ID:** UUID come `TEXT` su ogni tabella, stabili anche in vista di una futura sincronizzazione.
- **Importi:** `INTEGER` in **unità minori** (centesimi), sempre positivi. Il segno dipende dal `type`. Nell'app si usa `Decimal`. **Mai `Double`.**
- **Valuta:** codice ISO 4217 (`EUR`). **In v1 una sola valuta per tutta l'app**, scelta al primo avvio (default dalla `Locale`) **[DA CONFERMARE]**. Lo schema salva comunque la valuta per non precludere il multi-valuta.
- **Data dell'operazione:** **data di calendario** `TEXT` `YYYY-MM-DD`, senza fuso orario, così un'operazione non cambia mese viaggiando.
- **Timestamp tecnici** (`created_at`, `updated_at`): `TEXT` ISO 8601 in UTC.
- **Cancellazioni:** fisiche in v1. Le categorie si **archiviano** invece di essere cancellate, se hanno operazioni collegate.

### 6.2 Schema (migrazione `v1`)

```sql
CREATE TABLE account (
    id               TEXT PRIMARY KEY NOT NULL,
    name             TEXT NOT NULL,
    currency         TEXT NOT NULL,              -- ISO 4217
    initial_balance  INTEGER NOT NULL DEFAULT 0, -- unità minori, può essere negativo
    is_archived      INTEGER NOT NULL DEFAULT 0,
    sort_order       INTEGER NOT NULL DEFAULT 0,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
);

CREATE TABLE category (
    id           TEXT PRIMARY KEY NOT NULL,
    name         TEXT NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN ('income','expense')),
    symbol       TEXT NOT NULL,                  -- nome SF Symbol
    color        TEXT NOT NULL,                  -- token colore del DesignSystem
    is_archived  INTEGER NOT NULL DEFAULT 0,
    sort_order   INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);

-- "transaction" è parola riservata SQL: si usa "operation"
CREATE TABLE operation (
    id           TEXT PRIMARY KEY NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN ('income','expense')),
    amount       INTEGER NOT NULL CHECK (amount > 0),
    currency     TEXT NOT NULL,
    date         TEXT NOT NULL,                  -- YYYY-MM-DD
    account_id   TEXT NOT NULL REFERENCES account(id) ON DELETE RESTRICT,
    category_id  TEXT NOT NULL REFERENCES category(id) ON DELETE RESTRICT,
    note         TEXT,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);

CREATE INDEX idx_operation_date     ON operation(date DESC, created_at DESC);
CREATE INDEX idx_operation_category ON operation(category_id);
CREATE INDEX idx_operation_account  ON operation(account_id);

-- Metadati del database, usati da export/import (§ 10)
CREATE TABLE app_metadata (
    key    TEXT PRIMARY KEY NOT NULL,
    value  TEXT NOT NULL
);
-- Chiavi previste:
--   database_id        UUID generato alla creazione del DB (identifica la "storia" dei dati)
--   last_modified_at   ISO 8601 UTC, aggiornato a ogni scrittura su account/category/operation
--   last_modified_by   nome del dispositivo che ha fatto l'ultima modifica
```

- `last_modified_at` e `last_modified_by` sono aggiornati dal repository nella **stessa transazione** di ogni scrittura.

- `PRAGMA foreign_keys = ON` all'apertura (GRDB lo attiva di default).
- **Coerenza tipo/categoria:** `operation.kind` deve coincidere con `category.kind`. Lo verifica il repository, con un test dedicato.
- **Dati iniziali al primo avvio:**
  - un conto "Conto principale";
  - categorie di default:
    - uscite: Casa, Spesa, Trasporti, Ristoranti, Salute, Svago, Abbonamenti, Altro;
    - entrate: Stipendio, Rimborsi, Regali, Altro.

### 6.3 Query aggregate richieste

| Query | Uso |
|---|---|
| Somma entrate e uscite per un mese (`date BETWEEN 'YYYY-MM-01' AND 'YYYY-MM-31'`) | Home, Storico › Mesi |
| Ultime N operazioni (ordinate per `date DESC, created_at DESC`) | Home (N = 3) |
| Totali raggruppati per mese (`substr(date,1,7)`) | Storico › Mesi |
| Totali raggruppati per anno (`substr(date,1,4)`) | Storico › Anni |
| Operazioni di un periodo, con ricerca e filtri | Storico › Operazioni |

Tutte esposte come `ValueObservation`: la UI si aggiorna da sola dopo ogni inserimento, modifica o eliminazione.

### 6.4 Regole di calcolo

- **Entrate del mese** = somma `amount` con `kind = 'income'` nel mese.
- **Uscite del mese** = somma `amount` con `kind = 'expense'` nel mese.
- **Saldo del mese** = Entrate − Uscite. Positivo in colore neutro/verde, negativo in rosso. Il segno è sempre esplicito.
- **Mese corrente:** definito dal calendario e dal fuso orario correnti del dispositivo.
- **Formattazione:** `Decimal.FormatStyle.Currency` con la `Locale` dell'utente.

---

## 7. Navigazione

### 7.1 Mappa

```
App
├── Blocco (overlay sopra tutto, non fa parte della navigazione)
│     Face ID / Touch ID → in alternativa PIN
│
└── TabView (.sidebarAdaptable)
     ├── Tab "Home"            (SF Symbol: house)
     │    ├── Card del mese: Entrate · Uscite · Saldo
     │    ├── Ultime 3 operazioni → Dettaglio operazione
     │    │                       → "Vedi tutte": tab Storico
     │    ├── Aggiunta rapida: [+ Entrata] [+ Uscita] → sheet Editor
     │    └── Toolbar: Impostazioni (solo iOS/iPadOS)
     │
     ├── Tab "Storico"         (SF Symbol: list.bullet.rectangle)
     │    ├── Picker a segmenti: Operazioni | Mesi | Anni
     │    ├── Operazioni → Dettaglio operazione
     │    ├── Mesi → Operazioni del mese → Dettaglio
     │    └── Anni → Mesi dell'anno → Operazioni del mese → Dettaglio
     │
     └── Editor operazione (sheet modale, aperto da più punti)
```

### 7.2 Pulsante "Nuova operazione"

Le HIG riservano la tab bar alla **navigazione tra sezioni**, non alle azioni. Due opzioni:

- **Opzione A — conforme alle HIG (consigliata) [DA CONFERMARE]**
  - Tab bar con due soli tab: Home e Storico.
  - Pulsante "+" (`plus`) come `ToolbarItem(placement: .primaryAction)` in Home e Storico.
  - Su iOS/iPadOS 26+: pulsante "Nuova operazione" in `tabViewBottomAccessory`, sopra la tab bar, sempre a portata di pollice.
  - Su iOS 18: solo il "+" in toolbar e l'aggiunta rapida in Home.
- **Opzione B — "+" al centro della tab bar (richiesta originale)**
  - Tab centrale "finto" con icona `plus.circle.fill`. Alla selezione si apre lo sheet e si torna al tab precedente.
  - **Solo su iPhone** (size class compatta). Su iPad e Mac si applica comunque l'Opzione A, perché una voce-azione in sidebar non è accettabile.
  - Ordine dei tab: Home · [+] · Storico.

In entrambi i casi su Mac c'è la voce di menu **File › Nuova operazione** con **⌘N** (`CommandGroup(replacing: .newItem)`).

### 7.3 Implementazione della navigazione

- **Router di app** `@Observable AppRouter`, iniettato nell'`Environment`:
  - `selectedTab: AppTab` (`.home`, `.history`);
  - `editor: EditorRequest?`, con `EditorRequest` = `.new(kind: OperationKind?)` oppure `.edit(OperationID)`;
  - `historyPath: [HistoryRoute]`.
- `HistoryRoute`: `.operation(OperationID)`, `.month(YearMonth)`, `.year(Int)`.
- **Lo sheet dell'editor è presentato dalla radice**, una sola volta, così ogni punto dell'app lo apre impostando `router.editor`.
- **"Vedi tutte"** in Home: `selectedTab = .history`, segmento Operazioni, `historyPath = []`.
- **Storico:**
  - compatto (iPhone): `NavigationStack(path:)`;
  - regolare (iPad/Mac): `NavigationSplitView`, con elenco nella colonna `content` e dettaglio nella colonna `detail`.
- **Stato ripristinabile:** tab selezionato e segmento dello Storico salvati con `@SceneStorage`. Al ritorno dal blocco l'utente ritrova la stessa posizione, ma il dettaglio viene ricaricato dal DB.

### 7.4 Adattamento per piattaforma

| | iPhone | iPad | Mac |
|---|---|---|---|
| Navigazione principale | Tab bar in basso | Tab bar in alto, comprimibile in sidebar | Sidebar |
| Storico | Stack: elenco → dettaglio | `NavigationSplitView` | `NavigationSplitView`, colonne ridimensionabili |
| Editor | Sheet `.large` | Sheet `.formSheet` | Sheet sulla finestra |
| Impostazioni | Ingranaggio in toolbar Home → sheet | Come iPhone | Scena `Settings` (⌘,) |
| Blocco | Overlay a tutto schermo | Overlay a tutto schermo | Overlay sulla finestra + ⌃⌘L |
| Scorciatoie | — | Tastiera esterna: ⌘N, ⌘F | ⌘N nuova, ⌘F cerca, ⌘1/⌘2 cambia sezione, ⌫ elimina selezione, ⇧⌘E esporta DB, ⇧⌘I importa DB |
| Multi-finestra | No | No in v1 | Una sola finestra principale in v1 (`Window`, non `WindowGroup`) **[DA CONFERMARE]** |

---

## 8. Schermate

### 8.1 Blocco / Sblocco

**Primo avvio (onboarding, 3 passi):**
1. Benvenuto con una spiegazione breve su privacy e dati solo locali.
2. Impostazione del PIN a 6 cifre (inserimento + conferma).
3. Proposta di attivare Face ID / Touch ID (Attiva / Non ora) e scelta della valuta (quest'ultima dallo Sprint 2).

Al termine: salvataggio dell'hash del PIN, creazione del DB, migrazione `v1` e inserimento dei dati iniziali.

**Avvii successivi:**
- Se la biometria è attiva, il prompt biometrico parte **automaticamente** quando appare la schermata.
- Tastierino numerico PIN: 6 indicatori a pallino e pulsante "Usa Face ID" per ritentare.
- Errore: animazione di scossa dei pallini + feedback aptico di errore.
- Durante l'attesa per i troppi tentativi: messaggio "Riprova tra X minuti" e tastierino disabilitato.
- Nessun dato finanziario visibile prima dello sblocco.

### 8.2 Home

**Titolo:** "Home" (large title su iOS).

**Contenuto, dall'alto verso il basso:**

1. **Selettore del mese:** "‹ Ottobre 2026 ›". Le frecce cambiano mese, il tap sul titolo torna al mese corrente. Freccia "›" disabilitata oltre il mese corrente.
2. **Card riepilogo:**
   - Entrate (verde, `arrow.down.circle`);
   - Uscite (rosso, `arrow.up.circle`);
   - Saldo del mese (evidenziato).
3. **Aggiunta rapida:** due pulsanti affiancati **[+ Entrata]** e **[+ Uscita]**, che aprono l'editor con il tipo già impostato.
4. **Ultime operazioni:**
   - le **3 più recenti in assoluto**, non filtrate per il mese selezionato;
   - riga: icona categoria, nome categoria, nota troncata, data relativa ("Oggi", "Ieri", "12 ott"), importo con segno;
   - tap sulla riga → dettaglio operazione (push nel tab Home);
   - link "Vedi tutte" → tab Storico.
5. **Stato vuoto:** senza operazioni compare `ContentUnavailableView` con il messaggio "Nessuna operazione" e il pulsante "Aggiungi la prima".

**Toolbar:** "+" (Opzione A) · ingranaggio Impostazioni (iOS/iPadOS).

### 8.3 Storico

**Toolbar:** titolo "Storico" + `Picker` a segmenti **Operazioni | Mesi | Anni** (default: Operazioni).

**Segmento Operazioni:**
- elenco di tutte le operazioni, raggruppate per giorno con intestazioni ("Oggi", "Ieri", "Lunedì 26 ottobre");
- `.searchable`: ricerca su nota e nome della categoria;
- menu filtri in toolbar: tipo (Tutte/Entrate/Uscite), categoria, conto;
- swipe a sinistra → **Elimina**, con conferma;
- swipe a destra → **Modifica**;
- su Mac: menu contestuale con le stesse azioni, selezione con tastiera, ⌫ per eliminare;
- caricamento a pagine per elenchi lunghi, ad esempio 100 righe per volta.

**Segmento Mesi:**
- in testa: grafico Swift Charts a barre, entrate e uscite affiancate per gli ultimi 12 mesi;
- elenco dei mesi con almeno un'operazione, dal più recente;
- riga: "Ottobre 2026", entrate, uscite, saldo;
- tap → **Operazioni del mese**: stessa vista del segmento Operazioni filtrata sul mese, con un riepilogo in testa.

**Segmento Anni:**
- in testa: grafico a barre del saldo per anno;
- elenco degli anni con almeno un'operazione;
- riga: "2026", entrate, uscite, saldo;
- tap → **Mesi dell'anno** (stesso formato del segmento Mesi, limitato a quell'anno) → Operazioni del mese.

### 8.4 Dettaglio operazione

- In alto, grande: importo con segno e colore, poi categoria con icona.
- Campi: data (formato esteso), conto, nota, data di creazione e di ultima modifica (in piccolo).
- Toolbar:
  - **Modifica** → editor in modalità modifica;
  - **Elimina** (rosso, con conferma `confirmationDialog`) → torna indietro.

### 8.5 Editor operazione (nuova / modifica)

**Presentazione:** sheet con `NavigationStack` e `Form`.

**Toolbar:**
- **Annulla** (sinistra);
- **Salva** (destra, `.confirmationAction`), disabilitato finché il modulo non è valido.

**Titolo:** "Nuova operazione" / "Modifica operazione".

**Campi, in ordine:**

| Campo | Controllo | Default | Validazione |
|---|---|---|---|
| Tipo | `Picker` a segmenti Uscita / Entrata | Uscita, oppure quello passato dall'aggiunta rapida | Obbligatorio |
| Importo | Campo grande, tastierino decimale, **focus automatico** all'apertura | Vuoto | > 0, al massimo 2 decimali |
| Categoria | Griglia o elenco di icone filtrato per tipo | Ultima usata per quel tipo | Obbligatoria, coerente col tipo |
| Data | `DatePicker` (solo data) | Oggi | Nessun limite in v1 |
| Conto | `Picker` (nascosto se esiste un solo conto) | Conto principale | Obbligatorio |
| Nota | `TextField` multilinea | Vuota | Facoltativa, massimo 200 caratteri |

**Comportamento:**
- Se cambia il tipo, la categoria viene azzerata quando non è compatibile.
- Uscita con modifiche non salvate (Annulla o swipe giù): `confirmationDialog` "Scartare le modifiche?". Si usa `interactiveDismissDisabled` quando il modulo è stato modificato.
- Dopo il salvataggio: chiusura dello sheet + feedback aptico di successo. Home e Storico si aggiornano da soli tramite observation.
- Su Mac: ⏎ salva, ⎋ annulla.

### 8.6 Impostazioni

| Sezione | Voci |
|---|---|
| Sicurezza | Sblocco con Face ID/Touch ID (switch), Cambia PIN, Blocco automatico (solo Mac: 1/5/15/30 min) |
| Dati | Gestisci categorie, Gestisci conti, Esporta database, Importa database, Annulla ultimo import, Esporta CSV (§ 10) |
| Generale | Valuta (in sola lettura dopo la prima operazione in v1) |
| Informazioni | Versione, privacy ("I tuoi dati non lasciano mai questo dispositivo") |

- **Cambia PIN:** chiede il PIN attuale e quello nuovo (con conferma). Poi salva nel Keychain un nuovo salt e il nuovo hash, e azzera il contatore dei tentativi.
- **Gestisci categorie:** elenco diviso per Entrate/Uscite. Si possono aggiungere, rinominare, scegliere icona e colore, riordinare e archiviare.
- **Gestisci conti:** stesse funzioni.

---

## 9. Linee guida UI trasversali

- **HIG:**
  - large title su iOS;
  - SF Symbols per tutte le icone;
  - colori semantici di sistema più due token del DesignSystem: `income` (verde) e `expense` (rosso), con varianti chiare e scure.
- **Accessibilità:**
  - Dynamic Type supportato fino alle dimensioni di accessibilità;
  - etichette VoiceOver sugli importi (es. "Uscita, 45 euro e 20, Spesa, oggi");
  - contrasto conforme;
  - il colore non è mai l'unico indicatore: il segno +/− è sempre presente.
- **Dark mode** supportata nativamente.
- **Feedback aptico** (`sensoryFeedback`): successo al salvataggio, errore sul PIN sbagliato.
- **Localizzazione:** italiano come lingua base, struttura pronta per l'inglese. Importi e date sempre formattati con la `Locale`.
- **Privacy nello switcher:** overlay sfocato quando `scenePhase == .inactive` (§ 5.5).

---

## 10. Export e import del database (sincronizzazione manuale)

### 10.1 Principio

- Non c'è sincronizzazione automatica. Per allineare i dispositivi, l'utente **esporta il database** da un dispositivo e lo **importa** sull'altro, per esempio via AirDrop, app File, iCloud Drive o email.
- L'import **sostituisce interamente** il database locale. Non c'è unione dei dati in v1.
- Flusso tipico:
  - si lavora su un dispositivo alla volta;
  - prima di passare all'altro si esporta il database da quello usato per ultimo;
  - lo si importa sull'altro.

### 10.2 Formato del file

- **Estensione:** `.homefinances`. È un file SQLite standard, apribile con qualsiasi strumento SQLite.
- **Tipo di file (UTType):**
  - dichiarato come **Exported Type** in Info.plist, per esempio `it.<nomesviluppatore>.homefinances.database`;
  - conforme a `public.database` e `public.data`.
- **Associazione all'app:** registrata come **Document Type**, con l'app come handler principale. Toccare un file `.homefinances` in File, AirDrop o Mail apre l'app e avvia l'import.
- **Nome predefinito:** `Home Finances <dispositivo> <AAAA-MM-GG HHmm>.homefinances`, per esempio `Home Finances iPhone 2026-10-30 2145.homefinances`.
- **Contenuto:** l'intero database (conti, categorie, operazioni, `app_metadata`, tabella delle migrazioni GRDB).
- **Esclusi dal file:** PIN, impostazioni di biometria e preferenze locali come il timeout di blocco.

### 10.3 Export

- **Punti di accesso:**
  - Impostazioni › Dati › **Esporta database**;
  - su Mac anche **File › Esporta database…** (⇧⌘E).
- **Procedura:**
  1. copia consistente del DB in un file temporaneo con l'API di backup di GRDB (`try dbPool.backup(to: destinationQueue)`), sicura anche con l'app in uso;
  2. `VACUUM` sulla copia, per un file compatto e senza WAL separato;
  3. consegna all'utente:
     - **iOS/iPadOS:** `ShareLink`, che include AirDrop, Salva su File, Mail e Messaggi;
     - **macOS:** `fileExporter`, cioè il pannello Salva.
- **Avviso** prima dell'export (mostrato finché l'utente non sceglie "Non mostrare più"): "Il file contiene tutti i tuoi dati finanziari e non è protetto da password. Conservalo e invialo solo in modo sicuro."
- Dopo l'export, il file temporaneo viene cancellato.

### 10.4 Import

- **Punti di accesso:**
  - Impostazioni › Dati › **Importa database** (`fileImporter`, filtrato sul tipo `.homefinances`);
  - su Mac anche **File › Importa database…** (⇧⌘I);
  - apertura di un file `.homefinances` dall'esterno (`onOpenURL` / `handlesExternalEvents`).
- Se l'app è bloccata, l'import parte **solo dopo lo sblocco**.

**Procedura:**

1. Copia del file scelto in una cartella temporanea dell'app (con `startAccessingSecurityScopedResource` se serve).
2. **Validazione** del file copiato, aperto in sola lettura:
   - è un database SQLite valido e `PRAGMA integrity_check` restituisce `ok`;
   - contiene le tabelle attese e `app_metadata`;
   - versione dello schema:
     - **uguale o precedente** → accettato; le migrazioni si eseguono dopo l'import;
     - **più recente** di quella dell'app → rifiutato con il messaggio "Questo file è stato creato da una versione più recente dell'app. Aggiorna l'app e riprova."
3. **Schermata di confronto**, che va confermata:

| | Dati attuali (questo dispositivo) | File da importare |
|---|---|---|
| Ultima modifica | data/ora + dispositivo | data/ora + dispositivo |
| Operazioni | numero | numero |
| Operazione più recente | data | data |

   - Se i dati attuali sono **più recenti** del file, compare un avviso in evidenza: "I dati su questo dispositivo sono più recenti del file. Importando perderai le modifiche successive al [data]."
   - Se il `database_id` è diverso (i dati vengono da un database creato altrove), l'avviso lo dice esplicitamente.
   - Pulsanti: **Sostituisci i dati** (distruttivo, rosso) / **Annulla**.
4. **Copia di sicurezza automatica** del DB attuale in `Application Support/<bundle-id>/Backups/prima-import-<timestamp>.homefinances`. Si conservano le **ultime 3**.
5. **Sostituzione:**
   - chiusura del `DatabasePool`;
   - sostituzione atomica del file (`FileManager.replaceItemAt`), con eliminazione dei vecchi file `-wal` e `-shm`;
   - riapertura del DB ed esecuzione delle migrazioni.
6. **Aggiornamento dell'interfaccia:**
   - azzeramento della navigazione;
   - ritorno alla Home;
   - messaggio di conferma: "Dati importati: N operazioni".
7. **In caso di errore** in qualsiasi passo dopo la copia di sicurezza, si ripristina automaticamente la copia e si mostra l'errore.

- **Annulla ultimo import:** in Impostazioni › Dati si ripristina l'ultima copia di sicurezza. È disponibile se esiste almeno una copia.

### 10.5 Export CSV (solo lettura)

- Impostazioni › Dati › **Esporta CSV**, per l'uso in Excel o Numbers.
- Campi: `data;tipo;importo;valuta;categoria;conto;nota`, separatore `;`, UTF-8 con BOM, importi con la virgola decimale.
- Non è reimportabile: per spostare i dati tra dispositivi si usa il file `.homefinances`.

### 10.6 Fuori scope v1

- Unione (merge) di due database. Gli UUID e `updated_at` su ogni riga la rendono possibile in futuro.
- Import da CSV o estratti conto bancari.
- File di export protetto da password.

---

## 11. Test

**Unit test (Swift Testing):**
- `Core`: conversione Decimal ↔ unità minori, arrotondamenti, formattazione, calcolo del mese, regole di validazione dell'editor.
- `Persistence` (DB in memoria):
  - migrazioni;
  - CRUD;
  - vincoli (importo > 0, coerenza tipo/categoria, `RESTRICT` sulle FK);
  - aggregati mensili e annuali, compresi i casi limite: fine mese, anni bisestili, mesi senza operazioni.
- `Security`:
  - verifica del PIN corretto e di uno errato;
  - progressione dei tempi di attesa;
  - cambio PIN;
  - disattivazione della biometria quando cambia `evaluatedPolicyDomainState`;
  - ripristino da backup senza PIN → richiesta di un nuovo PIN.

**Test di integrazione:**
- apertura del DB su file reale in WAL, con letture concorrenti durante una scrittura;
- export → import: i dati importati sono identici (conteggi e checksum per tabella), incluso `app_metadata`;
- import di un file con schema precedente → migrazioni eseguite correttamente;
- import rifiutato in questi casi:
  - schema più recente;
  - file non SQLite;
  - file SQLite senza le tabelle attese;
  - `integrity_check` fallito;
- errore simulato durante la sostituzione → ripristino automatico della copia di sicurezza, senza perdita di dati;
- rotazione delle copie di sicurezza (ne restano 3) e "Annulla ultimo import";
- export eseguito mentre è in corso una scrittura → file consistente.

**Prova manuale di sincronizzazione:** export da iPhone → AirDrop → import su Mac, e ritorno dal Mac all'iPad tramite iCloud Drive.

**UI test (XCUITest):**
- onboarding;
- inserimento di un'operazione da Home → presenza in Storico;
- navigazione Anni → Mesi → Operazioni;
- blocco al ritorno dal background.

**Prove manuali per piattaforma:** iPhone (compatto), iPad (regolare + Split View/Stage Manager), Mac (finestra ridimensionata al minimo).

---

## 12. Piano di sviluppo

| Sprint | Contenuto | Uscita |
|---|---|---|
| 0 | Progetto multipiattaforma, pacchetti, GRDB via SPM, UTType `.homefinances` in Info.plist | Il DB si apre su iPhone, iPad e Mac |
| 1 | `Security`: PIN, biometria, AppLock, ciclo di vita, onboarding | Si sblocca e si blocca correttamente |
| 2 | `Persistence`: schema v1, dati iniziali, repository, query aggregate + test | Strato dati completo e testato |
| 3 | Navigazione (TabView, router, sheet) + Editor operazione | Si inseriscono e modificano operazioni |
| 4 | Home | Riepilogo mensile funzionante |
| 5 | Storico: Operazioni, Mesi, Anni, grafici, ricerca e filtri | Storico completo |
| 6 | Impostazioni, gestione categorie e conti, export/import | Funzionalità v1 complete |
| 7 | Accessibilità, localizzazione, rifinitura Mac (menu, scorciatoie), UI test | Release candidate |

---

## 13. Fuori scope v1 (possibili evoluzioni)

- **Cifratura del database con SQLCipher**, con la chiave protetta da PIN / biometria. Il codice è già predisposto (§ 5.6).
  - Il punto critico è l'integrazione GRDB + SQLCipher con Swift Package Manager, che richiede una build personalizzata o un fork.
  - Su Mac è l'unico modo per avere il file cifrato indipendentemente da FileVault.
- Sincronizzazione **automatica** tra dispositivi e unione (merge) di database diversi. In v1 la sincronizzazione è manuale (§ 10). Gli UUID e `updated_at` sono già predisposti.
- Multi-valuta con conversione.
- Trasferimenti tra conti.
- Budget per categoria.
- Operazioni ricorrenti.
- Widget, App Intents / Siri, Apple Watch.
- Import da CSV o estratti conto bancari.
- Allegati (foto degli scontrini).

---

## 14. Decisioni aperte

| # | Decisione | Proposta |
|---|---|---|
| 1 | Posizione del pulsante "Nuova operazione" | **Opzione A** (toolbar + accessorio tab bar), conforme alle HIG |
| 2 | Valuta | Una sola valuta per tutta l'app in v1 |
| 3 | ~~Cancellazione dei dati dopo N PIN errati~~ | **Decisa:** no in v1 |
| 4 | Multi-finestra su Mac | No in v1 |
| 5 | Ultime 3 operazioni in Home: assolute o del mese selezionato | Assolute |
| 6 | ~~Libreria di accesso dati~~ | **Decisa:** SQLite + GRDB diretto |
| 7 | Database incluso nel backup di sistema | Sì: così i dati non si perdono cambiando dispositivo |
