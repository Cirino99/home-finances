# Home Finances

App nativa per iPhone, iPad e Mac per tenere sotto controllo entrate e uscite.
I dati restano sul dispositivo: nessun server, nessun account.

> In sviluppo: le funzionalità della prima versione ci sono, ma non è ancora stata pubblicata.

## Funzionalità

- **Home:** entrate, uscite e saldo del mese, con le ultime operazioni e l'aggiunta rapida.
- **Storico:** operazioni e trasferimenti per giorno, con ricerca e filtri, anche per conto; riepiloghi per mese e per anno con grafici.
- **Conti:** saldo totale e saldo di ogni conto, ultime movimentazioni di un conto e trasferimenti da un conto all'altro, che non contano come entrate o uscite.
- **Blocco e cifratura:** PIN a 6 cifre, Face ID o Touch ID, blocco automatico; il database è cifrato con SQLCipher.
- **Categorie e conti:** personalizzabili; le categorie con icona e colore.
- **Export e import:** del database tra i tuoi dispositivi, con protezione opzionale tramite password, ed export in CSV.
- **Accessibilità:** VoiceOver, Dynamic Type e modalità scura.

## Privacy e sicurezza

- Nessun dato lascia il dispositivo, salvo i backup di sistema, che puoi disattivare nelle Impostazioni, e i file che esporti tu.
- **Il database è cifrato** con SQLCipher (AES-256), comprese le copie di sicurezza degli import. Si apre solo dopo lo sblocco e si chiude al blocco.
- La chiave del database è casuale e resta nel Keychain del dispositivo, avvolta da una chiave derivata dal PIN (PBKDF2, 600.000 iterazioni) e da una chiave del Secure Enclave: il PIN non si può provare fuori dal dispositivo. Face ID e Touch ID ne custodiscono una copia, che il sistema cancella se cambiano le biometrie registrate.
- Il PIN non viene mai salvato, nemmeno come hash.
- I file esportati con password sono cifrati con AES-256-GCM.

**Limiti da conoscere:**

- **La chiave non lascia il dispositivo.** Un backup di sistema ripristinato su un altro dispositivo non si apre: per spostare i dati usa l'export.
- **Se dimentichi il PIN, i dati non si possono recuperare.** Puoi solo cancellarli e ricominciare, poi importare un file esportato in precedenza. Lo stesso vale per la password di un file esportato.
- Il CSV e gli export senza password sono leggibili da chiunque abbia il file.
- Durante export e import esiste per poco tempo una copia in chiaro nella cartella temporanea dell'app, cancellata subito dopo.
- Dopo l'aggiornamento da una versione senza cifratura, i dati vengono cifrati al primo sblocco con il PIN. Su memoria flash la cancellazione del vecchio file in chiaro non garantisce che i blocchi siano illeggibili: li proteggono comunque la Data Protection di iOS e FileVault su Mac.
- Su un Mac senza Secure Enclave (Intel senza chip T2) la chiave del dispositivo è una chiave software nel Keychain: più debole contro chi ha accesso al Mac.

## Requisiti

- iOS, iPadOS o macOS 27
- Per compilare: Xcode 27.2 e Swift 6.4

Dipendenze esterne, gestite con Swift Package Manager a versione esatta:

- [GRDB.swift](https://github.com/groue/GRDB.swift) 7.12.0, dal fork ufficiale [sqlcipher/GRDB.swift](https://github.com/sqlcipher/GRDB.swift) collegato a SQLCipher (licenza MIT);
- [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift) 4.20.0, Community Edition di Zetetic (licenza BSD).

Le loro licenze sono riportate nell'app, in Impostazioni › Licenze. Come aggiornarle è spiegato nel [piano della cifratura](docs/PIANO-CIFRATURA.md).

## Compilare il progetto

1. Clona il repository.
2. Copia il modello della configurazione locale, ignorata da git:

   ```bash
   cp Config/Local.example.xcconfig Config/Local.xcconfig
   ```

3. Inserisci il tuo Team ID in `DEVELOPMENT_TEAM`. Serve anche su Mac, perché senza il Keychain risponde `-34018`. Non impostarlo dall'editor Signing & Capabilities di Xcode: finirebbe nel progetto versionato.
4. Apri `HomeFinances.xcodeproj` ed esegui lo schema `HomeFinances` con ⌘R. SQLCipher è collegato direttamente al target dell'app, così Xcode lo incorpora e lo firma: senza, macOS e un iPhone vero ne rifiutano il caricamento.

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
  Features/      Schermate: blocco, Home, Storico, Conti, editor, Impostazioni
  Tests/         Test
Config/          Configurazione di build
docs/            Specifiche e piani di sviluppo
```

Decisioni, modello dati, schermate e piano di sviluppo sono in [docs/SPECIFICHE.md](docs/SPECIFICHE.md). I riferimenti come `§ 5.2` nel codice rimandano a quel documento.

## Licenza

Nessuna licenza per ora: il codice è visibile, ma tutti i diritti restano riservati. Le componenti di terze parti hanno le loro licenze, elencate sopra.
