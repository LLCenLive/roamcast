# Roamcast

App iOS de live outdoor pour **LLCenLive** : balade à l'iPhone → vol au DJI Mini 2 → retour balade, **sans jamais couper Twitch**.
Matériel cible : iPhone 15 · DJI Mini 2 (radiocommande RC-N1) · DJI Mic Mini en Bluetooth.
Base de code issue du cahier des charges v1.1.

**Zéro euro, zéro Mac.** Compilation dans le cloud (GitHub Actions), signature et installation par AltStore avec un identifiant Apple gratuit.

---

## Mise en route, dans l'ordre

### 1. Le dépôt GitHub
- [ ] Créer un dépôt **public** `roamcast` sur GitHub. Public = minutes de compilation macOS gratuites et illimitées, et AltStore peut télécharger l'app sans authentification. Aucun secret n'est dans le code.
- [ ] Y pousser ce dossier (GitHub Desktop sur Windows fait ça en deux clics).

### 2. Les clés (gratuites)
- [ ] **Twitch** : dev.twitch.tv/console → « Enregistrer votre application ».
  URL de redirection : `http://localhost` (champ obligatoire, inutilisé par l'app). **Type de client : Public.** → récupérer le *Client ID*.
  Twitch exige la double authentification sur le compte pour accéder à la console.
- [ ] **DJI** : créer un compte sur developer.dji.com → Apps → créer une app iOS.
  ⚠️ **Le bundle ID à saisir est celui que l'app affiche une fois installée** (étape 5), pas `com.llcenlive.roamcast` : avec un compte Apple gratuit, AltStore modifie le bundle ID. Au premier build, on compile donc sans clé DJI ; ça ne bloque que la partie drone.

### 3. Les secrets GitHub
Dépôt → Settings → Secrets and variables → Actions → *New repository secret* :
- [ ] `TWITCH_CLIENT_ID`
- [ ] `DJI_APP_KEY` (à ajouter après l'étape 5, puis relancer un build)

### 4. La compilation
Chaque push sur `main` compile l'app (≈ 15-25 min). Pour relancer à la main : onglet **Actions** → *Build IPA* → *Run workflow*.
Si ça échoue : ouvrir le job, étape **« Erreurs de compilation »**, copier le contenu et le coller dans une conversation Roamcast avec Claude.

### 5. AltStore (une seule fois)
- [ ] Installer iTunes + iCloud **depuis le site Apple** (pas le Microsoft Store), puis AltServer sur le PC.
- [ ] Brancher l'iPhone en USB une fois, activer la synchro Wi-Fi dans iTunes.
- [ ] Installer AltStore sur l'iPhone via AltServer (identifiant Apple gratuit).
- [ ] Activer le mode développeur : Réglages → Confidentialité et sécurité.
- [ ] Dans AltStore → Sources → **+** → `https://raw.githubusercontent.com/<ton-compte>/roamcast/main/altstore/source.json` → installer Roamcast.
- [ ] Ouvrir Roamcast → **Journal de diagnostic** → noter le **Bundle ID réel** → créer la clé DJI avec (étape 2), l'ajouter en secret (étape 3), relancer un build, mettre à jour dans AltStore.

### 6. Renouvellement automatique (sinon l'app expire au bout de 7 jours)
- [ ] **PC – Planificateur de tâches** (mercredi + dimanche) :
  ```
  schtasks /Create /TN "AltServer Start" /SC WEEKLY /D WED,SUN /ST 20:00 /TR "\"C:\Program Files (x86)\AltServer\AltServer.exe\""
  schtasks /Create /TN "AltServer Stop"  /SC WEEKLY /D WED,SUN /ST 20:30 /TR "taskkill /IM AltServer.exe /F"
  ```
  Vérifier le chemin d'AltServer. Sur la tâche « Start » : Conditions → « Réveiller l'ordinateur pour exécuter cette tâche ».
- [ ] **iPhone – Raccourcis → Automatisation** « Heure de la journée », mercredi + dimanche à 20 h 10 → action AltStore « Actualiser toutes les apps », « Exécuter immédiatement » coché.
- [ ] **Réflexe avant chaque live** : ouvrir AltStore la veille et vérifier les jours restants (bouton « Refresh » au besoin).

Limites du compte gratuit : 3 apps installées de cette façon au maximum (AltStore compris), expiration à 7 jours sans renouvellement.

### 7. Mises à jour
Modifier le code → push → GitHub compile → la nouvelle version apparaît dans AltStore → « Mettre à jour ». Plus rien à faire à la main.

---

## Phase 0 – checklist terrain (jalon obligatoire du CDC)

Tout se fait en **mode essai** (interrupteur dans l'écran de préparation : rien n'est envoyé sur Twitch), avec le **Journal de diagnostic** ouvert. Chaque ligne ci-dessous correspond à un message du journal.

- [ ] Le build GitHub passe (le SDK DJI compile avec le Xcode actuel)
- [ ] `[DJI] SDK enregistré` (clé DJI valide pour le bundle ID réel)
- [ ] RC-N1 branchée en USB-C → `[DJI] Produit : DJI Mini 2`
- [ ] `[DJI] 1er paquet vidéo brut reçu`
- [ ] `[DJI] 1re image drone décodée : …×…` (sinon : `SANS CVPixelBuffer` → problème de décodage à corriger)
- [ ] Bascule vers le drone : l'image s'affiche dans l'aperçu, télémétrie cohérente
- [ ] Débrancher la radiocommande en plein flux → écran brandé, retour iPhone après 5 s, pas de crash
- [ ] Écouter le DJI Mic Mini en Bluetooth (`[Audio] Entrée : …` et fréquence en Hz)

En cas de souci : **Copier** dans le journal, coller dans une conversation avec Claude.
Quand ces cases sont cochées, le reste du CDC (Phases 1 à 6) est déjà en place dans la base de code.

---

## L'idée qui tient tout le projet

```
 CameraManager ──► LatestFrameBox ─┐
                                    ├─► VideoPipeline (timer 30 i/s, TOUJOURS actif)
 DJIManager ─────► LatestFrameBox ─┘        │
                                            ├─ scène : live(iPhone) | live(drone) | slate("…")
                                            ├─ Compositor (aspect-fill, fondu, overlays)
                                            ▼
                                     LivePublisher (RTMP) ──► Twitch
```

Les sources **poussent** leurs images dans une boîte ; le pipeline les **tire** à cadence fixe.
L'encodeur reçoit donc une image toutes les 33 ms quoi qu'il arrive :

- bascule iPhone → drone = on change `scene`, c'est tout ;
- drone qui décroche en vol = la boîte se vide, le compositeur affiche l'écran brandé, puis retour iPhone auto après 5 s ;
- DJI Mic Mini qui se déconnecte = bascule immédiate sur le micro iPhone ;
- réseau perdu = reconnexion RTMP avec backoff, bitrate de reprise plus bas.

Seul `SessionManager.stop()` (après confirmation) peut fermer le RTMP. C'est vérifié par la machine à états (`SessionState.allowsRTMPClose`) et par les tests.

---

## Arborescence

| Dossier | Contenu | CDC |
|---|---|---|
| `Roamcast/Core/` | Machine à états, `SessionManager` (orchestration), presets, formats | §3, §4, §14 |
| `Roamcast/Streaming/` | `VideoPipeline`, `Compositor`, `LivePublisher` (HaishinKit / mode essai), bitrate adaptatif | §8, §10, §11, §13 |
| `Roamcast/Audio/` | `AudioEngine` (mix micro + musique), `Ducker`, `MusicManager` | §7 |
| `Roamcast/Sources/` | `CameraManager`, `DJIManager` + `SimulatedDrone` | §5, §8, §9 |
| `Roamcast/Location/` | GPS, distance, **localisation publique dégradée** | §6 |
| `Roamcast/Twitch/` | OAuth (Device Code Flow), Helix, chat IRC | §4.3, §12 |
| `Roamcast/Support/` | Journal de diagnostic, Keychain, réseau, batterie, température | §17 |
| `Roamcast/UI/` | Préparation, Live (5 boutons), préparation drone, panneaux, diagnostic | §4, §5, §17 |
| `RoamcastTests/` | Scénario MVP, invariant RTMP, ducking, bitrate, confidentialité, chat | §19 |
| `.github/workflows/` | Compilation cloud → IPA non signée → Release → source AltStore | — |
| `altstore/` | Source AltStore (mise à jour par la CI) + icône | — |

---

## Choix techniques notables

- **Pas de signature à la compilation.** L'IPA sort non signée de GitHub ; AltStore la signe avec ton identifiant Apple gratuit au moment de l'installer.
- **Permissions de la source AltStore lues dans l'IPA** (`scripts/update_altstore_source.py`) : AltStore refuse une app dont les permissions déclarées ne correspondent pas.
- **Mode essai dans l'app** : on ne peut pas régler de variable d'environnement sans Xcode.
- **OAuth Twitch par Device Code Flow.** Une app iOS ne peut pas garder un `client_secret`. Ce flow est prévu pour les clients publics : l'app affiche un code, tu valides sur twitch.tv/activate. Les refresh tokens publics sont à usage unique et expirent après 30 jours d'inactivité : le code remplace systématiquement l'ancien.
- **Métadonnées ≠ RTMP.** `TwitchAPI` ne connaît pas le moteur vidéo. Modifier titre/catégorie/tags à chaud n'a aucun effet sur le flux.
- **Rendu toujours en 1080p30**, l'encodeur met à l'échelle en Éco (720p).
- **Pas de larsen.** Le mix broadcast est capté par un tap ; la sortie haut-parleur est muette.
- **`automaticallyConfiguresApplicationAudioSession = false`** sur la capture caméra, sinon AVFoundation reconfigure la session audio et le micro Bluetooth saute.
- **Localisation :** la position exacte ne sort jamais de `LocationManager`. L'approximation se cale sur une grille fixe de 0,05° (~5 km). Deux points proches donnent la même valeur, donc impossible de trianguler en moyennant dans le temps.
- **Mode arrière-plan audio** : si l'écran se verrouille, la caméra s'arrête mais l'app reste vivante. Le live continue sur l'écran brandé au lieu de couper.

---

## Ce qui n'a PAS été vérifié

Le code a été écrit sans Xcode. La logique pure (états, ducking, bitrate, grille GPS) et le script de source AltStore ont été vérifiés. En revanche, **rien n'a encore été compilé** : le premier build GitHub sera le vrai juge, et il faut s'attendre à une ou deux passes de corrections. Les endroits les plus exposés :

1. **`Streaming/LivePublisher.swift` – adaptateur HaishinKit.** L'API a beaucoup changé entre 1.x et 2.x (acteurs, `async`, modules séparés). C'est le seul fichier à réaligner une fois la version épinglée.
2. **`Sources/DJIManager.swift` – SDK DJI V4.16 + DJIWidget.** Le schéma « `DJIVideoPreviewer` en décodage matériel → `cv_pixelbuffer_fastupload` » est celui des exemples DJI ; son comportement exact avec le Mini 2 est l'objet de la Phase 0.
3. **`.bluetoothHighQualityRecording`** (iOS 26) : option récente, à confirmer avec le DJI Mic Mini.

---

## Risques matériels

- **Un seul port sur l'iPhone.** En mode drone, la RC-N1 occupe le port USB-C. Le DJI Mic Mini doit donc rester en **Bluetooth direct**, ce qui passe par le profil HFP : son de qualité « téléphone ». À écouter en vrai dès la Phase 0. Si c'est trop mauvais, les pistes sont : l'option iOS 26 haute qualité, un hub USB-C (compatibilité MFi DJI à vérifier), ou le récepteur du micro branché en balade seulement.
- **iPhone 15 (USB-C) + SDK DJI V4.** DJI Fly fonctionne avec la RC-N1 en USB-C ; pour une app tierce basée sur le SDK V4, c'est à valider en tout premier (étape « Produit : DJI Mini 2 » de la Phase 0).
- **SDK DJI V4 en fin de vie.** Il faut valider la compilation avec le Xcode actuel (c'est le premier build GitHub qui le dira).
- **Chauffe.** Caméra + H.264 + 5G + GPS + Bluetooth en plein soleil : `DeviceMonitor` alerte et suggère le profil Éco. Il faudra le tester sur une vraie rando d'une heure.

---

## Hors V1 (conservé du CDC)

Multi-drones, Android, YouTube/Kick, Spotify, alertes subs, sauvegarde locale, carte détaillée, favoris de spots, stream markers.
Le changement de qualité **pendant** le live n'est pas prévu non plus : le profil se choisit avant « Lancer le live », et ensuite seul le bitrate s'adapte.
