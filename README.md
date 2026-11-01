# Home Finances

App nativa per iPhone, iPad e Mac per tenere sotto controllo entrate e uscite.
I dati restano sul dispositivo: nessun server, nessun account.

> In sviluppo: le funzionalità della prima versione ci sono, ma non è ancora stata pubblicata.

## Funzionalità

- **Home:** entrate, uscite e saldo del mese, con le ultime operazioni e l'aggiunta rapida.
- **Storico:** operazioni per giorno con ricerca e filtri, riepiloghi per mese e per anno con grafici.
- **Blocco:** PIN a 6 cifre, Face ID o Touch ID, blocco automatico.
- **Categorie e conti:** personalizzabili, con icona e colore.
- **Trasferimento dei dati:** export e import del database tra i tuoi dispositivi, con protezione opzionale tramite password, ed export in CSV.
- **Accessibilità:** VoiceOver, Dynamic Type e modalità scura.

## Privacy e sicurezza

- Nessun dato lascia il dispositivo, salvo i backup di sistema, che puoi disattivare nelle Impostazioni, e i file che esporti tu.
- Il PIN non viene mai salvato in chiaro: nel Keychain c'è solo un hash PBKDF2.
- I file esportati con password sono cifrati con AES-256-GCM.

**Limiti da conoscere:**

- Il database sul dispositivo **non è cifrato** dall'app: il PIN protegge l'accesso dall'interfaccia, non il file. Valgono le protezioni del sistema, come la Data Protection di iOS e FileVault su Mac.
- Il CSV e gli export senza password sono leggibili da chiunque abbia il file.
- Se dimentichi il PIN e ci sono dati, non si possono recuperare. Lo stesso vale per la password di un file esportato.

## Requisiti

- iOS, iPadOS o macOS 27
- Per compilare: Xcode 27.2 e Swift 6.4

L'unica dipendenza esterna è [GRDB.swift](https://github.com/groue/GRDB.swift), gestita con Swift Package Manager.

## Compilare il progetto

1. Clona il repository.
2. Copia il modello della configurazione locale, ignorata da git:

   ```bash
   cp Config/Local.example.xcconfig Config/Local.xcconfig
   ```

3. Inserisci il tuo Team ID in `DEVELOPMENT_TEAM`. Serve anche su Mac, perché senza il Keychain risponde `-34018`. Non impostarlo dall'editor Signing & Capabilities di Xcode: finirebbe nel progetto versionato.
4. Apri `HomeFinances.xcodeproj` ed esegui lo schema `HomeFinances` con ⌘R.

Per chi usa il progetto con un proprio Team, il bundle identifier `it.simonecirino.homefinances` va probabilmente cambiato.

> Nelle build Debug il database viene cancellato se lo schema cambia: non usarle con dati a cui tieni.

## Test

In Xcode con ⌘U, oppure da terminale:

```bash
cd Packages && swift test
```

Se `xcode-select` punta ai Command Line Tools, i test non compilano: anteponi `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

I test dell'interfaccia si fanno a mano: l'elenco è nelle [specifiche](docs/SPECIFICHE.md#11-test).

## Struttura

```
HomeFinances/    App: avvio, navigazione principale, export e import
Packages/
  Core/          Modelli, regole, protocolli dei repository
  Persistence/   Database (GRDB), repository, export e import
  Security/      PIN, Keychain, biometria, blocco
  DesignSystem/  Componenti condivisi
  Features/      Schermate: blocco, Home, Storico, editor, Impostazioni
  Tests/         Test
Config/          Configurazione di build
docs/            Specifiche
```

Decisioni, modello dati, schermate e piano di sviluppo sono in [docs/SPECIFICHE.md](docs/SPECIFICHE.md). I riferimenti come `§ 5.2` nel codice rimandano a quel documento.

## Licenza

Nessuna licenza per ora: il codice è visibile, ma tutti i diritti restano riservati.
