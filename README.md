# Rilievo LiDAR – versione 4

App per iPad/iPhone con LiDAR (iPadOS/iOS 17 o successivo) per il rilievo di ambienti.

## Funzioni

- **Archivio rilievi**: elenco dei progetti con nome, data e anteprima. Si possono rinominare ed eliminare.
- **Scansione stanze (RoomPlan)**: pareti, porte, finestre e arredi. Se scansioni più stanze di seguito, senza chiudere la schermata, restano allineate e vengono unite in un unico modello.
- **Scansione mesh con foto**: mesh LiDAR reale con texture ricavate dai fotogrammi. Salva anche le foto con la posizione della camera, per la fotogrammetria.
- **Foto annotate**: durante entrambe le scansioni puoi scattare foto e aggiungere una nota. Le foto della scansione stanze compaiono numerate sulla pianta.
- **Misure**: superficie, perimetro e altezza di ogni stanza, più le dimensioni di pareti, porte, finestre (con parapetto) e arredi.
- **Percorso dell'operatore**: registrato in entrambe le scansioni. Compare sulla pianta (PDF/DXF), nel visualizzatore mesh e come `percorso.obj` nello ZIP.
- **Visualizzatore mesh** (ispirato a Polycam):
  - *Righello* a più tratti con totale, *Area* (reale e in pianta), *Calibra* la scala su una misura nota
  - *Note 3D* appuntate sulla mesh
  - *Sezione orizzontale* a quota scelta, esportabile in DXF (pianta anche all'aperto)
  - *Tour* lungo il percorso dalle posizioni delle foto, con foto sovrapponibile
  - Vista dall'alto, griglia di 1 m, screenshot
- **Export PLY** della mesh colorata (CloudCompare, MeshLab, Recap)
- Scansione mesh fino a 500 fotogrammi
- **Galleria delle foto della mesh**: tutti i fotogrammi salvati, orientati e condivisibili.
- **Pausa durante le note**: nella scansione mesh la registrazione delle foto si ferma mentre scrivi la nota.
- **Anteprima 3D** del modello delle stanze.

## Esportazioni

| File | Contenuto |
|---|---|
| Modello stanze (USDZ) | Modello 3D schematico, con più stanze unite |
| Pianta quotata (PDF) | Pianta con quote, porte e finestre, tabella delle misure e pagine con foto e note |
| Pianta (DXF) | Linee su layer MURI, PORTE, FINESTRE, ARREDI, QUOTE, FOTO (in metri) |
| Misure (CSV) | Tabella per Excel (separatore ; e virgola decimale) |
| Mesh (ZIP) | `modello.obj` + `modello.mtl` con texture, cartella `foto/`, `camere.json` e `camere.csv` con le pose delle foto, `LEGGIMI.txt` |

## Build automatica (GitHub Actions)

Ad ogni modifica sul ramo `main` parte da sola la build **Build IPA**. L'IPA si scarica dagli *Artifacts* e si installa con Sideloadly.

## Struttura

- `project.yml`: progetto XcodeGen (iOS 17)
- `RilievoLiDAR/`: codice Swift
- `.github/workflows/build-ipa.yml`: build dell'IPA non firmato
