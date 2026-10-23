# Claude Pet

Un petit compagnon en pixel-art qui vit par-dessus le bureau macOS et réagit à ce que fait Claude Code
(CLI `claude` et onglet Code de Claude Desktop), via les hooks de Claude Code.

```
Claude Code ──hook──▶ curl POST 127.0.0.1:47319/event ──▶ ClaudePet.app ──▶ sprite
```

## Lancer

Il faut macOS 13+ et Swift 5.10+ (les Command Line Tools suffisent, pas besoin de Xcode).

```bash
swift run ClaudePet
```

Le pet apparaît en bas à droite, avec une patte dans la barre des menus (Masquer, Vivre dans l'encoche, Position,
Taille, Quitter). Glisse-le à la souris : sa position est mémorisée. Un clic droit dessus ouvre le même menu.

### Mode encoche

Sur un MacBook à encoche, coche **Vivre dans l'encoche** (⌘N dans le menu). Le pet s'accroupit, s'envole vers
l'encoche en s'inclinant, et un cadre noir sort de l'encoche pour le recevoir. Décocher refait le trajet en sens inverse,
jusqu'à sa dernière position flottante. Le choix est mémorisé au relancement.

- Le cadre commence 14 pt *sous* l'encoche, où l'écran n'a pas de pixels : la jonction avec l'encoche physique, coin
  arrondi compris, est invisible. Il a la hauteur exacte de l'encoche (`safeAreaInsets.top`) et un petit arrondi
  concave en haut à droite, comme celui de l'encoche.
- Dans l'encoche, le pet utilise un sprite compact (le corps recadré, avec l'icône d'état à côté au lieu d'une bulle),
  ce qui permet de le dessiner à l'échelle 2 dans 32 pt.
- Au survol : retour haptique (`NSHapticFeedbackManager`, seulement si le doigt est posé sur un trackpad Force Touch),
  et le cadre et le pet grandissent avec un ressort (×4). Le cadre se referme quand le curseur s'éloigne.
- Le cadre déplié recouvre temporairement les icônes de barre des menus qui sont juste à droite de l'encoche.
- Si l'encoche disparaît (écran externe seul, capot fermé), le pet revient en mode flottant.

### Glisser-déposer vers l'encoche et hors de l'encoche

On peut aussi changer de mode à la main, sans le menu :

- **Vers l'encoche** : attrape le pet et approche-le de l'encoche. Plus il s'en approche, plus il rétrécit, et le cadre
  noir commence à sortir de l'encoche. Assez près, un retour haptique signale la zone de dépôt, le cadre gonfle et le
  pet est aimanté vers sa place. Lâche-le : il glisse dans le cadre, s'écrase un instant (« plop ») et le cadre se
  rétracte sur lui.
- **Hors de l'encoche** : attrape le pet (ou le cadre) et tire-le. Il reste un peu collé avant de se détacher, reprend
  sa taille normale en s'éloignant, et le cadre rentre dans l'encoche. Lâché hors de la zone, il atterrit là où tu le
  poses, toujours entièrement à l'écran et sous la barre des menus.
- Pendant le drag, le pet s'incline selon sa vitesse horizontale. Un simple clic lui fait faire un petit rebond.

Pour une vraie app (sans icône Dock, lançable depuis le Finder ou au login) :

```bash
scripts/bundle.sh && open build/ClaudePet.app
```

Port : `CLAUDE_PET_PORT=12345 swift run ClaudePet` (passe le même `--port` à l'installeur).

## Tester sans Claude

```bash
scripts/fake-event.sh demo
```

Autres commandes : `multi` (deux sessions en parallèle), `prompt`, `tool Edit`, `fail Bash`, `notify`, `stop`, `state`…
Lance `scripts/fake-event.sh` sans argument pour la liste complète.

`swift run ClaudePet --export-sprites sprites-export` écrit toutes les frames en PNG (×8).

## Brancher Claude Code

```bash
scripts/install-hooks.py install --dry-run   # montre le diff, n'écrit rien
scripts/install-hooks.py install             # montre le diff, demande confirmation, sauvegarde, écrit
scripts/install-hooks.py uninstall           # retire uniquement nos hooks
```

- Le script fusionne dans `~/.claude/settings.json` sans toucher aux autres hooks (vibe-island, etc.). Nos entrées sont
  repérées par le commentaire `# claude-pet-hook`, ce qui rend `install` idempotent et `uninstall` propre.
- Avant d'écrire, il copie le fichier dans `settings.json.claude-pet-backup-<date>`.
- Les sessions Claude Code déjà ouvertes ne voient les nouveaux hooks qu'après redémarrage (ou via `/hooks`).

Chaque hook lance `curl -m 1 --connect-timeout 0.2 … || exit 0` sur le JSON stdin du hook, et sort toujours avec 0.

**Pourquoi un envoi synchrone et pas en arrière-plan ?** En arrière-plan, un gros `PostToolUse` (sortie d'un Read
de plusieurs Mo) arrivait *après* le `PreToolUse` suivant, et le pet affichait le mauvais état. En synchrone, Claude
Code attend la fin de chaque hook, donc l'ordre est garanti. Coût mesuré : ~10 ms par hook, ~30 ms pour 5 Mo,
quasi nul si l'app est fermée (connexion refusée), 1 s au pire si l'app est bloquée.

## États

| Événement hook | État |
|---|---|
| `SessionStart` | au repos |
| `UserPromptSubmit`, `PreCompact`, `PostToolUse`, `SubagentStop` | réfléchit (bulle « … ») |
| `PreToolUse` | travaille, icône selon l'outil : `>_` Bash, crayon Edit/Write, loupe Read/Grep/Glob, globe Web, deux blocs Task/Agent, engrenage pour le reste (MCP…) |
| `SubagentStart` | travaille (agent) |
| `PostToolUseFailure` | erreur pendant 3 s, puis réfléchit |
| `StopFailure` | erreur pendant 3 s, puis au repos |
| `PermissionRequest`, `Notification` (sauf `idle_prompt`) | t'attend (« ! » jaune) |
| `Stop` | content (cœur) pendant 5 s, puis au repos |
| `SessionEnd` | la session est oubliée |
| aucune activité depuis 5 min | dort |

Garde-fous : un état « travaille » ou « réfléchit » sans événement depuis 10 min repasse au repos (un Échap
n'envoie pas de `Stop`), et une session muette depuis 3 h est oubliée.

### Plusieurs sessions

Le pet suit **la session dont l'état est le plus prioritaire** : t'attend > erreur > travaille > réfléchit > content >
au repos. En cas d'égalité, c'est la plus récemment active qui gagne. Une session qui a besoin de toi n'est donc jamais
masquée par une autre qui travaille. Le menu affiche le nombre de sessions suivies.

## Protocole (pour un futur mod)

`POST http://127.0.0.1:47319/event` avec un objet JSON :

- le JSON du hook tel quel (`hook_event_name`, `session_id`, `tool_name`, `cwd`, `notification_type`…) ;
- ou un forçage direct : `{"session_id": "...", "pet_state": "happy", "pet_tool": "bash", "pet_duration": 2}`.
  `pet_state` prend `idle|thinking|working|error|waiting|happy|sleeping`, `pet_tool` prend `bash|edit|read|web|agent|other`,
  et `pet_duration` (en secondes, facultatif) ramène ensuite la session au repos.

`POST /control` règle l'app : `{"notch": true}` ou `{"notch": false}` (avec l'animation).

`GET /state` renvoie l'état agrégé, les sessions et `notch`, `GET /health` permet de vérifier que l'app tourne. Le serveur
n'écoute que sur 127.0.0.1 et refuse les requêtes qui portent un en-tête `Origin` (pages web).

## Code

- `Sources/ClaudePet/PetState.swift` : états, correspondance hook → état, agrégation multi-sessions.
- `Sources/ClaudePet/Sprites.swift` : sprites placeholder générés en code (grille 24×22). C'est ici qu'on branchera
  de vrais assets.
- `Sources/ClaudePet/Notch.swift` : géométrie de l'encoche, forme du cadre noir, ressorts.
- `Sources/ClaudePet/PetWindow.swift` : NSPanel non activant, transparent, au-dessus de la barre des menus, sur tous
  les Spaces et en plein écran. Modes flottant / encoche et vol entre les deux. Il laisse passer les clics partout sauf sur les pixels opaques du sprite (le curseur est interrogé
  30 fois par seconde, sans permission Accessibilité).
- `Sources/ClaudePet/EventServer.swift` : serveur HTTP minimal (Network.framework).
- `Sources/ClaudePet/AppDelegate.swift` : menu de la barre des menus, câblage.

Pourquoi un Swift Package plutôt qu'un projet Xcode : il se compile avec `swift build` sans Xcode, il n'y a pas de
fichier projet à maintenir, et `scripts/bundle.sh` suffit pour produire le `.app` (avec `LSUIElement`).
