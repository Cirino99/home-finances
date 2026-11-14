# Piano di sviluppo — Cifratura del database

> Evoluzione prevista dal § 13 delle [specifiche](SPECIFICHE.md); i rimandi `§` puntano lì.
> Versione 1.0 — 14 novembre 2026: tutte le decisioni del § 5 sono confermate. L'integrazione esatta di SQLCipher (§ 3.1) si sceglie allo step 1.

---

## 1. Obiettivo

Cifrare il file del database con **SQLCipher**, così i dati sono illeggibili senza la chiave anche fuori dall'app: copiando il file, da un backup, su un Mac senza FileVault. La chiave sta nel Keychain e si apre solo con il **PIN** o con **Face ID / Touch ID**.

Oggi il PIN protegge solo l'interfaccia (§ 5.1). Dopo questo lavoro protegge anche il file.

## 2. Situazione di partenza

Il codice è già predisposto (§ 5.6):

- il database si apre solo in `AppDatabase.open(at:configuration:)`, e solo `Persistence` conosce GRDB e il percorso del file;
- le feature usano solo i protocolli dei repository;
- non si usano estensioni SQLite assenti in SQLCipher.

Cambiano però più cose del solo punto di apertura:

| Area | Oggi | Con la cifratura |
|---|---|---|
| Apertura | All'avvio, prima dello sblocco | Solo dopo lo sblocco: prima la chiave non c'è |
| "Ci sono dati?" | Si chiede al database (`isSeeded`), anche da bloccato | Va deciso senza aprirlo (§ 3.6) |
| PIN | Hash PBKDF2 nel Keychain, solo per verificarlo | Deriva la chiave che apre la chiave del database |
| Biometria | Un token nel Keychain protetto da `.biometryCurrentSet` | Al posto del token, la chiave del database |
| Export | `backup(to:)` verso un file in chiaro | `sqlcipher_export` verso un file in chiaro, poi la password opzionale come oggi |
| Import e copie "prima-import" | File in chiaro | Il file importato viene cifrato prima della sostituzione, e anche le copie |
| Ripristino da backup su un altro dispositivo | Funziona con un nuovo PIN (§ 5.5) | Senza la chiave, che non lascia il dispositivo, il file non si apre (§ 3.5) |

---

## 3. Decisioni di progetto

### 3.1 Integrazione di SQLCipher con GRDB (scelta allo step 1)

È il punto critico già indicato nel § 13. GRDB supporta SQLCipher, ma la via ufficiale è stata a lungo CocoaPods, che non usiamo. Con Swift Package Manager servono una build di GRDB collegata a SQLCipher invece che al SQLite di sistema, e un pacchetto SQLCipher.

Lo step 1 è una prova tecnica, senza codice dell'app, che sceglie tra le strade disponibili:

| Opzione | Come | Da verificare |
|---|---|---|
| A — pacchetti ufficiali | Pacchetto SPM di SQLCipher (Community Edition, Zetetic) e la variante di GRDB che lo usa, se GRDB 7 la offre per SPM | Che esistano per SPM nella versione attuale, compatibili con Swift 6.4 e con le piattaforme 27 |
| B — fork di GRDB | Un fork mantenuto di GRDB già collegato a SQLCipher (ne esistono di usati in produzione) | Chi lo mantiene, quanto segue GRDB, licenza |
| C — fork nostro | Una copia di GRDB nel repository, collegata a SQLCipher | Costo di aggiornamento a ogni versione di GRDB |

Criteri per la scelta, in ordine:

1. compila e funziona su iPhone, iPad e Mac, e con `swift test`;
2. **nessun conflitto con il SQLite di sistema**: i framework Apple lo caricano comunque, e due SQLite nello stesso processo possono scambiarsi i simboli, finendo per usare quello non cifrato senza errori evidenti. La prova deve verificare `PRAGMA cipher_version` dall'app, non solo dai test;
3. aggiornamenti semplici di GRDB e SQLCipher;
4. licenza compatibile: SQLCipher Community è BSD.

È una **seconda dipendenza esterna** oltre a GRDB, in deroga al § 3 delle specifiche.

#### Scelta (step 1, 14 novembre 2026)

**Opzione A, con il fork ufficiale [`sqlcipher/GRDB.swift`](https://github.com/sqlcipher/GRDB.swift)**, versione esatta `7.12.0`.

- **Il fork:** è un "managed fork" creato a febbraio 2026 dal team di SQLCipher, che si è impegnato a seguire ogni versione di GRDB. L'autore di GRDB lo ha approvato ([discussione #1854](https://github.com/groue/GRDB.swift/discussions/1854)), e la documentazione di GRDB lo indica come il modo consigliato per usare SQLCipher con SPM. Il suo `Package.swift` applica le modifiche "GRDB+SQLCipher" del `Package.swift` di GRDB.
- **SQLCipher:** pacchetto ufficiale di Zetetic, [`SQLCipher.swift`](https://github.com/sqlcipher/SQLCipher.swift), dipendenza del fork. Si resta sulla serie 4: la 5.0, in beta, non apre i database della 4.
- **Perché non un fork nostro:** lo step 1 era partito con `Cirino99/GRDB.swift`, perché il fork ufficiale non era emerso dalla ricerca. Il fork ufficiale non aggiunge nessuno di nuovo di cui fidarsi (GRDB e Zetetic sono già dipendenze), non richiede lavoro a ogni aggiornamento e non dipende da un repository personale. Un fork nostro servirebbe solo per modifiche nostre, o per controllare ogni aggiornamento prima di adottarlo.
- **Scartati i fork di terzi** (per esempio GRDB 7.5 con SQLCipher 4.9): indietro o senza aggiornamenti verificabili.
- **Il resto del codice** non usa il SQLite di sistema direttamente (nessun `import SQLite3` né `sqlite3_`): tutto passa da GRDB.
- **Licenza:** SQLCipher Community è BSD, e la sua licenza va riportata nell'app e nella documentazione (step 7).

**Regole per gli aggiornamenti:**

- versione esatta (`exact:`) in `Packages/Package.swift`: un aggiornamento entra solo quando lo si decide;
- `Package.resolved` nel repository: registra il commit di ogni dipendenza, e Xcode segnala un tag spostato;
- prima di aggiornare, leggere il changelog di GRDB e di SQLCipher e guardare le differenze del `Package.swift` del fork, la parte che decide cosa viene collegato;
- dopo, i test di `SQLCipherTests` devono passare: se tornasse il SQLite di sistema, se ne accorgerebbero.

**Prova:** `SQLCipherTests` verifica che `PRAGMA cipher_version` risponda 4.x (con il SQLite di sistema non risponde), che il file cifrato si apra solo con la sua chiave, che nei suoi byte non ci sia testo in chiaro, e che un database in chiaro si apra ancora senza chiave, cosa che servirà per la migrazione e per l'import. Il controllo dall'app, e non solo dai test, arriva con lo step 3, all'apertura del database.

**Esito (14 novembre 2026):** prova superata con il fork `Cirino99/GRDB.swift` (`7.12.0-sqlcipher.1`) e SQLCipher.swift 4.20.0: compila su iPhone e Mac, e tutti i test passano, compresi quelli di `SQLCipherTests`. Lo stesso giorno, dopo il passaggio al fork ufficiale (`sqlcipher/GRDB.swift` 7.12.0), la prova è stata ripetuta con lo stesso esito.

### 3.2 Gerarchia delle chiavi

```
Chiave del database (DEK)          256 bit casuali, generata una volta
 ├─ avvolta dal PIN                 AES-256-GCM con una chiave derivata dal PIN
 │                                  (PBKDF2-HMAC-SHA256, ≥ 600.000 iterazioni, salt casuale)
 │   └─ avvolta dal Secure Enclave  chiave P-256 non esportabile del dispositivo
 └─ copia per la biometria          voce del Keychain con `.biometryCurrentSet`
```

- **La DEK non cambia mai** in v1: cambiare il PIN avvolge di nuovo la stessa chiave, senza ricifrare il database.
- **Verifica del PIN:** è la riuscita dell'apertura AES-GCM, il cui tag rifiuta una chiave sbagliata. L'hash del § 5.2 non serve più. Contatore dei tentativi e attese (§ 5.2) restano identici, nel Keychain.
- **Perché il Secure Enclave:** un PIN di 6 cifre ha solo un milione di combinazioni. Chi copiasse la DEK avvolta dal solo PIN potrebbe provarle tutte fuori dal dispositivo, anche con 600.000 iterazioni, in tempi ragionevoli con hardware dedicato. Avvolgerla anche con una chiave del Secure Enclave, che non esce dal dispositivo, obbliga a fare ogni tentativo sul dispositivo stesso. Su Mac serve un Mac con Apple silicon o con chip T2.
- **Tutte le voci** sono `ThisDeviceOnly`: non finiscono nei backup né su altri dispositivi.
- **SQLCipher riceve la chiave grezza** (`PRAGMA key = "x'…'"`, con l'API di passphrase di GRDB) invece di una password: niente derivazione di SQLCipher a ogni apertura, che sarebbe lenta e inutile su una chiave già casuale.

### 3.3 Biometria

- La voce del Keychain con `.biometryCurrentSet` contiene la **DEK** (avvolta dal Secure Enclave, se confermato) invece del token casuale di oggi. Lo sblocco con Face ID la legge e apre il database: se la lettura riesce, la chiave è giusta per costruzione.
- **Cambio delle biometrie registrate:** il sistema cancella la voce, come oggi. L'app chiede il PIN e, se l'utente accetta, ricrea la copia (§ 5.3).

### 3.4 Ciclo di vita

- Al blocco l'app **chiude il database e cancella la chiave dalla memoria**; allo sblocco lo riapre. Oggi il database resta aperto per tutta la sessione (§ 5.4) perché il blocco agisce solo sull'interfaccia. Con la cifratura, tenere la chiave in memoria mentre l'app è bloccata toglierebbe buona parte del vantaggio.
- La riapertura costa poco: la derivazione lenta dal PIN si fa comunque allo sblocco.
- Su iPhone l'app si blocca a ogni passaggio in background (§ 5.4), quindi chiuderà e riaprirà il database spesso. L'interfaccia si ricostruisce già al blocco (`LockGate` rimuove il contenuto), quindi non cambia nulla di visibile.
- Scartata l'alternativa di tenere il database aperto per la sessione, come oggi: più semplice, ma la chiave resterebbe in memoria finché l'app vive.

### 3.5 Ripristino su un altro dispositivo

Le chiavi sono `ThisDeviceOnly` (§ 3.2), quindi **un database ripristinato da un backup su un altro dispositivo non si apre**, nemmeno con il PIN giusto. Oggi invece l'app chiede il codice del dispositivo e fa scegliere un nuovo PIN (§ 5.5).

- Lo si accetta e lo si dice chiaramente. Per spostare i dati su un altro dispositivo si usa il file di export (§ 10), che è già il modo previsto. Se l'app trova un database cifrato senza la chiave, spiega che i dati vengono da un altro dispositivo e offre due strade: importare un file `.homefinances`, oppure ricominciare da zero dopo il codice del dispositivo e una conferma esplicita.
- **Alternativa scartata:** mettere nei backup la DEK avvolta dal solo PIN. Funzionerebbe, ma riaprirebbe l'attacco fuori dal dispositivo descritto nel § 3.2, perché chiunque abbia il backup potrebbe provare il milione di PIN.
- Sullo stesso dispositivo (aggiornamento dell'app, ripristino del backup sullo stesso iPhone) il Keychain resta, e i dati si aprono.

### 3.6 Sapere se ci sono dati senza aprire il database

`AppLock` deve sapere, da bloccato, se ci sono dati, per decidere se il PIN dimenticato si può reimpostare (§ 5.2) e se si tratta di un ripristino (§ 5.5). Un database cifrato esiste **e** contiene dati se esiste il file e se nel Keychain c'è la DEK avvolta; un database nuovo e vuoto non viene creato finché non c'è la chiave. Non serve leggere il contenuto.

### 3.7 Export, import e copie di sicurezza

- **Il formato del file `.homefinances` non cambia:** l'export decifra con `sqlcipher_export` verso un file in chiaro temporaneo, poi lo protegge con la password opzionale come oggi (§ 10.2). I file restano leggibili da un altro dispositivo, con chiavi diverse, e dalle versioni precedenti dell'app. La password resta facoltativa, attiva di default.
- **Import:** il file arriva in chiaro, o lo diventa dopo la password, e viene controllato come oggi (§ 10.4). Prima della sostituzione viene cifrato con la DEK locale con `sqlcipher_export`. L'import non cambia la chiave del dispositivo.
- **Copie "prima-import" e "Annulla ultimo import":** sono cifrate con la DEK, come il database. Oggi sono file in chiaro.
- **File temporanei in chiaro** durante export e import: esistono già oggi. Restano nella cartella temporanea dell'app per il tempo minimo e si cancellano subito, come ora.

### 3.8 Migrazione dei dati esistenti (§ 5.6)

Al **primo sblocco con il PIN** dopo l'aggiornamento (serve il PIN per creare la DEK avvolta):

1. si verifica il PIN con l'hash di oggi;
2. si genera la DEK e si salvano nel Keychain le versioni avvolte; se la biometria è attiva, il token viene sostituito dalla copia della DEK;
3. si apre il file in chiaro e lo si esporta in un file cifrato con `sqlcipher_export`, nella stessa cartella;
4. si controlla il file cifrato (`integrity_check`, stesso numero di righe per tabella) e lo si sostituisce in modo atomico, poi si cancellano `-wal` e `-shm` del vecchio file;
5. si cifrano allo stesso modo, o si cancellano, le copie "prima-import" in chiaro;
6. si cancella l'hash del PIN.

Ogni passo deve poter ripartire se l'app si chiude a metà: un segnaposto nella cartella dice a che punto si è, e il file in chiaro si cancella solo quando quello cifrato è al suo posto e verificato. Lo sblocco con Face ID funziona solo dopo la migrazione: fino ad allora l'app chiede il PIN.

**Limite da dichiarare:** su memoria flash la cancellazione del file in chiaro non garantisce che i blocchi siano illeggibili. Su iPhone e iPad la Data Protection lo rende comunque inaccessibile senza il dispositivo sbloccato; su Mac vale FileVault.

### 3.9 Fuori scope

- Rotazione della DEK, cioè ricifrare tutto il database con una chiave nuova.
- Recupero dei dati con PIN dimenticato: resta impossibile per scelta (§ 5.2), e con la cifratura lo diventa anche tecnicamente.
- Cifratura del CSV (§ 10.6).

---

## 4. Piano di sviluppo

Ogni step si chiude con il codice che compila e i test che passano. Compilazione e test li esegui tu. Dopo la tua conferma ti propongo il commit, poi si passa allo step successivo.

| Step | Contenuto | File principali | Uscita |
|---|---|---|---|
| **0** | Decisioni confermate. Specifiche alla 1.17: § 3 (dipendenze), § 5 (sicurezza, ciclo di vita, ripristino), § 10 (export e import), § 13. Il README cambia allo step 7, quando la cifratura c'è davvero | `docs/` | Specifiche allineate |
| **1** | **Prova di integrazione.** SQLCipher e GRDB con SPM secondo il § 3.1, senza toccare l'app. Test che apre un database con una chiave, lo riapre, fallisce con la chiave sbagliata, legge `cipher_version` | `Packages/Package.swift`, nuovo test in `PersistenceTests` | Opzione scelta, dipendenza aggiunta, test che girano su iPhone, iPad e Mac |
| **2** | **Chiavi.** In `Security`: generazione della DEK, avvolgimento con il PIN e con il Secure Enclave, copia per la biometria, cambio PIN che riavvolge, verifica del PIN con l'apertura AES-GCM, tentativi e attese invariati. Interfaccia astratta per il Secure Enclave, sostituibile nei test | nuovo `Security/DatabaseKeyStore.swift`, `PasscodeService.swift`, `Biometrics.swift`, `AppSecurity.swift` + test in `AppSecurityTests` | Chiave ottenuta da PIN o biometria, testata senza dispositivo |
| **3** | **Apertura cifrata.** `AppDatabase.open(at:key:)` con la chiave grezza. `DatabaseStore` con stato "bloccato": apre il database solo con la chiave, lo chiude al blocco se confermato. "Ci sono dati?" senza aprirlo (§ 3.6). Avvio, sblocco e blocco nell'app | `AppDatabase.swift`, `DatabaseStore.swift`, `HomeFinancesApp.swift`, `AppRoot.swift` + test | Un'installazione nuova lavora su un database cifrato |
| **4** | **Migrazione** dei dati in chiaro (§ 3.8), ripartibile, comprese le copie di sicurezza e la sostituzione del token biometrico | `DatabaseStore.swift`, nuovo `Persistence/DatabaseEncryptionMigration.swift`, `AppSecurity.swift` + test | Un'installazione esistente passa alla cifratura senza perdere dati |
| **5** | **Export, import e copie** (§ 3.7): export con `sqlcipher_export` verso il formato di oggi, import cifrato con la DEK prima della sostituzione, copie "prima-import" cifrate, validazione invariata | `DatabaseStore.swift`, `DatabaseInspector.swift` + test in `DatabaseStoreTests` | Sincronizzazione manuale invariata per l'utente |
| **6** | **Casi limite nell'interfaccia:** database cifrato senza chiave (§ 3.5), testi del PIN dimenticato, biometria cambiata, errori di apertura | `LockFeature`, `AppRoot.swift`, `AppSecurity.swift` | Nessun vicolo cieco per l'utente |
| **7** | **Rifinitura:** prestazioni su un database grande, prova su Mac (Keychain e provisioning), export compliance (§ 5.5), prove manuali, specifiche e README | vari | Funzionalità pronta |

### 4.1 Dipendenze tra gli step

- Lo step 1 decide se e come si procede: se nessuna opzione soddisfa i criteri del § 3.1, il piano si ferma lì.
- Lo step 2 non dipende da SQLCipher e potrebbe andare in parallelo all'1, ma conviene farlo dopo, per non scrivere codice inutile se la prova fallisce.
- Gli step 3, 4 e 5 vanno in ordine: tutti toccano `DatabaseStore`.
- **Lo step 4 deve essere nello stesso rilascio dello step 3**: una versione che apre solo database cifrati senza migrare quelli esistenti renderebbe illeggibili i dati di chi aggiorna. Fino allo step 4 il codice dello step 3 non va pubblicato.

### 4.2 Test previsti

**Unit test:**
- DEK avvolta e aperta con il PIN giusto; rifiuto del PIN sbagliato; tentativi e attese come oggi.
- Cambio PIN: la stessa DEK, la vecchia versione avvolta non funziona più.
- Biometria: copia creata, letta, cancellata al cambio delle biometrie; ripristino dopo il PIN.
- PIN dimenticato senza dati: azzeramento di chiavi e contatori.

**Test di integrazione:**
- Database cifrato su file: si apre con la chiave, non con un'altra, e senza chiave non è leggibile come SQLite (`file is not a database`).
- I byte del file non contengono testo delle note né nomi di categorie.
- Migrazione da un database in chiaro con dati: stesso contenuto, nessun file in chiaro rimasto, copie "prima-import" cifrate.
- Migrazione interrotta a ogni passo e ripresa: nessuna perdita di dati.
- Export da un database cifrato: file in chiaro o con password, importabile da un altro database con chiave diversa.
- Import di un file della versione precedente: accettato, cifrato con la chiave locale.
- "Annulla ultimo import" con copie cifrate.

**Prove manuali:**
- aggiornamento da una versione senza cifratura con dati reali, su iPhone e su Mac;
- sblocco con PIN e con Face ID, blocco e riapertura ripetuti;
- cambio delle biometrie registrate;
- ripristino di un backup su un altro dispositivo: messaggio e strade del § 3.5;
- export da iPhone e import su Mac.

### 4.3 Note di sviluppo

- **Step 1:** fork ufficiale `sqlcipher/GRDB.swift` (§ 3.1). `SQLCipher.swift` è un XCFramework già compilato e firmato da Zetetic: va aggiunto **direttamente al target dell'app** con "Embed & Sign", alla stessa versione esatta risolta per GRDB. Altrimenti Xcode non lo copia nell'app e macOS ne rifiuta il caricamento perché firmato da un altro Team ("different Team IDs"); nel simulatore iOS il controllo non c'è, su un iPhone vero sì. Nel progetto: pacchetto `SQLCipher.swift` a versione esatta e prodotto `SQLCipher` collegato direttamente al target, che Xcode incorpora e firma da solo (una fase di copia scritta a mano non funziona con i prodotti dei pacchetti), e `LD_RUNPATH_SEARCH_PATHS` in `Config/Base.xcconfig` (`@executable_path/Frameworks` su iOS, `@executable_path/../Frameworks` su macOS), che prima mancava perché l'app non incorporava framework. Le versioni si decidono in due punti distinti: GRDB in `Packages/Package.swift`, SQLCipher nel progetto Xcode. Il fork chiede SQLCipher `from: "4.11.0"` e SwiftPM risolve una sola versione per tutto: quella esatta del progetto vale anche per GRDB. Se una nuova versione del fork chiedesse un SQLCipher più recente, la risoluzione dei pacchetti fallisce finché non si aggiorna anche il progetto.
- **Step 2:** la chiave nasce con il PIN dell'onboarding, oppure, per chi ha già un PIN, al primo sblocco con il PIN, che sostituisce l'hash; nello stesso momento il token di Face ID diventa la copia della chiave. Fino ad allora Face ID sblocca, ma senza dare la chiave. Se manca la chiave del dispositivo è un errore, non un PIN sbagliato, e non consuma tentativi. Dove manca il Secure Enclave (simulatore) il livello del dispositivo usa una chiave software nel Keychain, `ThisDeviceOnly`.
- **Step 3:**
  - lo store nasce chiuso e si apre allo sblocco con la chiave; al blocco si chiude e la dimentica;
  - un database nuovo nasce cifrato; uno **in chiaro** di prima della cifratura si apre ancora senza chiave, così lo step 3 non rompe le installazioni esistenti. Lo step 4 sostituisce questo passaggio con la migrazione;
  - un database cifrato e una sessione senza chiave (Face ID con il vecchio token) chiedono il PIN;
  - "ci sono dati?" senza aprire il database (§ 3.6): nessun file, no; file in chiaro, lo si legge; file cifrato, sì se accanto c'è il segno `homefinances.sqlite.seeded`, lasciato dall'inserimento dei dati iniziali e dall'import;
  - fino allo step 5 export, import e copie di sicurezza funzionano solo con il database in chiaro: con quello cifrato l'export fallisce con un errore e l'import si ferma prima di toccare i dati;
  - la chiave resta in memoria finché l'`AppDatabase` chiuso non viene rilasciato: Swift non garantisce di poterla azzerare.
- **Step 4:**
  - la migrazione parte all'apertura con la chiave, quindi al primo sblocco con il PIN (o con Face ID, dopo che il PIN ha sostituito il token); senza chiave il database resta in chiaro;
  - database e copie "prima-import" si cifrano uno alla volta con `sqlcipher_export` in un file accanto (`….encrypting`), controllato (`integrity_check` e stesse righe per tabella) prima della sostituzione atomica;
  - il segnaposto `homefinances.sqlite.encryption-migration` dice solo che una migrazione è cominciata: a ogni tentativo si decide dal formato reale dei file, quindi un'interruzione in qualsiasi punto riparte senza perdere dati;
  - se la migrazione fallisce (per esempio per lo spazio) tutto resta com'era, il database si apre in chiaro e si riprova al prossimo sblocco; l'errore è in `DatabaseStore.encryptionMigrationError`, da mostrare allo step 6;
  - l'apertura dello store è asincrona e la migrazione gira lontano dal main thread; un blocco durante la migrazione non apre nulla, e uno sblocco successivo riparte con la nuova chiave.

### 4.4 Rischi

| Rischio | Effetto | Contromisura |
|---|---|---|
| Nessuna integrazione SPM affidabile | Il piano non parte | Lo step 1 decide prima di scrivere codice dell'app |
| SQLite di sistema al posto di SQLCipher | Database non cifrato senza errori evidenti | `cipher_version` verificato dall'app e da un test; test sui byte del file |
| Migrazione interrotta | Dati persi o doppi | Passi ripartibili; il file in chiaro si cancella per ultimo |
| Chiave persa (Keychain azzerato, dispositivo ripristinato) | Dati illeggibili | È il comportamento voluto; l'export resta il backup portabile, e l'app deve dirlo |
| Prestazioni | Avvio e sblocco più lenti | Chiave grezza, nessuna derivazione di SQLCipher; misure allo step 7 |
| Export compliance | Pubblicazione bloccata o dichiarazione errata | Da ricontrollare prima della pubblicazione (§ 5.5); non è una valutazione legale |

---

## 5. Decisioni

Tutte confermate il 14 novembre 2026.

| # | Decisione | Scelta |
|---|---|---|
| 1 | Integrazione SPM (§ 3.1) | Fork ufficiale `sqlcipher/GRDB.swift`, versione esatta, e SQLCipher.swift ufficiale |
| 2 | Seconda dipendenza esterna (§ 3.1) | Sì, SQLCipher Community |
| 3 | Secure Enclave nella gerarchia delle chiavi (§ 3.2) | Sì, contro i tentativi fuori dal dispositivo |
| 4 | Chiusura del database al blocco (§ 3.4) | Sì, con la chiave cancellata dalla memoria |
| 5 | Ripristino su un altro dispositivo (§ 3.5) | Non supportato: si usa l'export; l'app lo spiega e offre import o ripartenza |
| 6 | Formato e password dell'export (§ 3.7) | Formato invariato, password ancora facoltativa |
