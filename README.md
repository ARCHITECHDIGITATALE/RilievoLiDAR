# Rilievo LiDAR

App iPadOS/iOS che esegue il rilievo di una stanza con RoomPlan (LiDAR) ed esporta il modello in USDZ.

- **Avvia scansione** / **Termina scansione**
- A fine elaborazione il file `Rilievo_<data>.usdz` viene salvato nei Documenti dell'app (visibile anche nell'app File, sotto "Sul mio iPad › Rilievo LiDAR") e si può inviare con **Condividi USDZ**.

Requisiti: iPad Pro (2020 o successivi) o iPhone Pro con LiDAR, iPadOS/iOS 16+.

## Build automatica (GitHub Actions)

1. Carica il contenuto di questa cartella in un nuovo repository GitHub, **inclusa la cartella nascosta `.github`**.
2. Vai in **Actions → Build IPA → Run workflow**.
3. A fine build scarica l'artefatto **RilievoLiDAR-ipa** (è uno zip che contiene `RilievoLiDAR.ipa`).
4. Installa l'IPA sull'iPad con **Sideloadly** usando il tuo Apple ID. Con un Apple ID gratuito l'app va rifirmata ogni 7 giorni.

Se la cartella `.github` non viene caricata, crea il workflow a mano: in GitHub vai su **Actions → set up a workflow yourself**, chiama il file `build-ipa.yml` e incolla il contenuto di `.github/workflows/build-ipa.yml`.

## Struttura

- `project.yml` — definizione del progetto per XcodeGen (il `.xcodeproj` viene generato dalla build)
- `RilievoLiDAR/` — codice Swift
- `.github/workflows/build-ipa.yml` — build dell'IPA non firmato

Per aprirlo su un Mac: `brew install xcodegen && xcodegen generate`, poi apri `RilievoLiDAR.xcodeproj`.
