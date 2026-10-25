# Vidéo de démo du site

Fabrique `site/public/demo.mp4` (1920×1200, 16:10, H.264, 60 i/s, ~40 s, sans son) et
`site/public/demo-poster.jpg`, à partir d'une vraie prise sur le MacBook (écran intégré, encoche),
avec un faux curseur et des zooms façon Screen Studio ajoutés au montage.

```bash
scripts/demo-video/record.sh  /tmp/claude-pet-demo           # ~1 min, bouge la vraie souris
scripts/demo-video/render.py  /tmp/claude-pet-demo site/public/demo.mp4 \
    --poster site/public/demo-poster.jpg --poster-time 1.0   # ~1 min 15
scripts/demo-video/render.py  /tmp/claude-pet-demo /dev/null --stills /tmp/st 5,11.6,27.5   # images de contrôle
```

Pendant la prise (~45 s), ne touche ni la souris ni le clavier : le pilote envoie de vrais
événements souris (`CGEvent`), le pet ne réagit qu'à ceux-là. Il faut la permission
« Enregistrement de l'écran » pour l'app qui lance le script (sinon `capture` échoue, rien n'est
contourné).

## Ce que fait chaque pièce

- `record.sh` : compile les outils, lance une instance **privée** du pet (port 47400,
  `CLAUDE_PET_NO_PUBLISH=1`, `CLAUDE_PET_HOOKS_HOME` dans le dossier de travail, interface en
  anglais), la met dans l'encoche, repère la position de l'icône de la barre des menus (le panneau
  s'ouvre centré dessous), capture le fond d'écran seul, lance la fausse barre des menus, puis la
  capture et le pilote. Il écrit dans le domaine `ClaudePet` (celui du binaire nu, jamais
  `local.claude-pet`) : `usageAPIEnabled = false` (pas de Trousseau), `setupAccepted`,
  `tutorialDone`, `petScale = 6`, `petInNotch`. Il ne tue que l'instance qu'il a lancée.
- `capture.swift` : ScreenCaptureKit, écran intégré en 2× natif, 60 i/s, HEVC 120 Mb/s. Le filtre
  ne contient que trois sources : la fenêtre « Wallpaper » de WindowManager (macOS 26+), le pet et
  la fausse barre des menus ; `showsCursor = false`. Les autres apps, les icônes et widgets du
  bureau, la vraie barre des menus et les notifications ne peuvent donc pas apparaître. Écrit
  `take.mov.json` avec l'heure (horloge hôte) de la première image.
- `menubar.swift` : une vraie fenêtre juste au-dessus du fond d'écran, en haut de l'écran : le fond
  assombri, l'icône du pet (sa silhouette, yeux évidés, à la vraie position x) et une horloge
  (9:41). Comme c'est une fenêtre, WindowServer place le pet au-dessus, exactement comme au-dessus de
  la vraie barre. Sur l'écran réel, elle reste cachée sous la vraie barre et laisse passer les clics.
- `drive.swift` : le scénario (événements de hooks factices sur `/event`, demandes sur `/ask`,
  quotas sur `/status`, mouvements, clics et glissers réels à 60 Hz avec courbes adoucies). Chaque
  position du curseur et chaque étape (`mark`) est journalisée avec `CACurrentMediaTime()`, la même
  horloge que celle des images capturées. Le bouton Allow de la carte flottante est retrouvé à
  partir de la fenêtre de la carte.
- `cursor.swift` : exporte la flèche système (`NSCursor.arrow`, 280×400 px) et son point chaud.
- `render.py` : Python + numpy + PIL, ffmpeg en entrée (décodage) et en sortie (x264). Redessine
  l'encoche physique (la capture voit à travers : rectangle 663,5–848,5 × 32 pt, coins du bas de
  10 pt, oreilles de 6 pt comme `NotchGeometry`), applique la caméra (plans définis par rapport aux
  `mark`, zoom vers un point fixe, smootherstep, recadrage toujours dans l'écran), dessine le faux
  curseur (×1,5, ombre douce, léger rétrécissement et onde au clic), fondu au début et à la fin.

## Scénario (temps de la vidéo)

0–1,4 s plan large · réfléchit · 3,2 s laptop (Bash) · 7,6 s « Claude needs you » dans l'encoche ·
le curseur survole, le panneau s'ouvre, clic sur Allow (12,2 s) · laptop puis content (14,8 s) ·
survol du pet (jauges) et glisser hors de l'encoche (17,4–19,3 s) · deuxième demande : pastille,
survol, carte, Allow (24,2 s) · clic sur l'icône de la barre des menus, panneau des quotas (34 %,
21 %, 18 %), refermé par un second clic · glisser du pet dans l'encoche (31,5–33,2 s) · content,
retour au plan large, fondu.

Pour changer le scénario : les temps sont dans `take()` (`drive.swift`), les plans de caméra dans
`moves` (`render.py`), accrochés aux noms des `mark`.

## Limites connues

- Écrit pour l'écran intégré du MacBook Pro 14" (1512×982 pt, encoche à x 663,5–848,5) : ailleurs,
  ajuster `NOTCH`, `SRC_W/SRC_H` et les positions du pilote.
- Les positions du pilote (bouton Allow du panneau de l'encoche, point de dépôt) sont mesurées sur
  cette géométrie ; la carte flottante et l'icône sont retrouvées à chaque prise.
- Le fond d'écran doit être fixe (pas de fond animé) pour que la prise reste propre.
