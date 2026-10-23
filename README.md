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
  arrondi compris, est invisible. Replié, il a la hauteur exacte de l'encoche (`safeAreaInsets.top`).
- Ses coins ont les rayons de l'encoche native, quelle que soit sa taille : 10 pt en bas (aussi pour le raccord concave
  sous l'encoche quand il est déplié) et 6 pt pour le petit arrondi concave en haut. Ce sont de vrais arcs de cercle.
  Pour s'ouvrir, il glisse de derrière l'encoche au lieu de s'élargir, donc ses coins restent intacts.
- macOS n'expose pas la forme de l'encoche, donc ces rayons sont estimés. Pour les ajuster à l'œil, compare avec le
  coin inférieur gauche de l'encoche : `curl -d '{"notch_radius": 11, "notch_ear": 5}' 127.0.0.1:47319/control`
  (la valeur est mémorisée).
- Dans l'encoche, le pet utilise un sprite compact (le corps recadré, avec l'icône d'état à côté au lieu d'une bulle),
  ce qui permet de le dessiner à l'échelle 2 dans 32 pt.
- Au survol : retour haptique (`NSHapticFeedbackManager`, seulement si le doigt est posé sur un trackpad Force Touch),
  et le cadre et le pet grandissent avec un ressort (×4). Le cadre se referme quand le curseur s'éloigne.
- Le cadre déplié recouvre temporairement les icônes de barre des menus qui sont juste à droite de l'encoche.
- Si l'encoche disparaît (écran externe seul, capot fermé), le pet revient en mode flottant.

### Jauges d'usage

Dans l'encoche, trois anneaux entourent le pet : **bleu** en bas à gauche pour le quota 5 h, **violet** en bas à droite
pour le quota de la semaine, **vert** en haut à droite pour la fenêtre de contexte de la session suivie. Au survol, ils
grandissent avec le cadre et affichent leur pourcentage. Passer sur un anneau affiche le détail (« Quota 5 h : 50 % ·
reset dans 2 h 04 »).

Aucune source officielle ne stocke ces chiffres. Le pet les lit en lecture seule, et la donnée la plus récente gagne :

| Source | Donne | Quand |
|---|---|---|
| Ligne de statut de Claude Code (relais `statusline.sh`) | quotas 5 h et semaine, contexte exact | sessions `claude` dans un terminal (Desktop ne l'exécute pas) ; quotas pour Pro/Max, après la première réponse |
| `~/Library/Application Support/Claude/plan-usage-history.json` | quotas | quand Claude Desktop l'écrit (au plus toutes les 270 s ; parfois plus du tout) |
| Transcript de la session (chemin reçu avec chaque hook) | contexte estimé (« ≈ », taille de fenêtre supposée : 200k, ou 1M au-delà) | toutes les sessions, Desktop compris |

Une donnée trop vieille pour sa fenêtre, ou dont la fenêtre a été réinitialisée, est affichée comme inconnue (anneau
vide), jamais comme 0 %. L'endpoint `/usage` de claude.ai donnerait des quotas frais dans Desktop, mais il exige le
cookie de session du compte : il n'est volontairement pas utilisé.

`install-hooks.py` remplace la commande de ta ligne de statut par le relais, qui transmet le JSON au pet puis lance ta
commande d'origine (sauvegardée dans `~/Library/Application Support/claude-pet/statusline-original`) : l'affichage du
terminal ne change pas. `uninstall` la remet en place.

### Glisser-déposer vers l'encoche et hors de l'encoche

On peut aussi changer de mode à la main, sans le menu :

- **Vers l'encoche** : attrape le pet et approche-le de l'encoche. Il reste exactement sous ton curseur et prend peu à
  peu la taille qu'il a dans l'encoche survolée, pendant que le cadre noir commence à sortir de l'encoche. Assez près,
  un retour haptique signale la zone de dépôt, et le cadre s'ouvre comme au survol. Lâche-le : il glisse à sa place et
  s'écrase un instant (« plop »). Le cadre se replie ensuite normalement quand la souris s'en va.
- **Hors de l'encoche** : attrape le pet (ou le cadre survolé) et tire-le. Le cadre se rentre dans l'encoche à mesure
  que tu t'éloignes, et le pet reprend sa taille normale. Lâché hors de la zone, il atterrit là où tu le
  poses, toujours entièrement à l'écran et sous la barre des menus.
- Pendant le drag, le pet s'incline selon sa vitesse horizontale. Un simple clic lui fait faire un petit rebond.

Pour une vraie app (sans icône Dock, lançable depuis le Finder ou au login) :

```bash
scripts/bundle.sh && open build/ClaudePet.app
```

Port : 47319 par défaut (`CLAUDE_PET_PORT=12345 swift run ClaudePet` pour en préférer un autre). S'il est occupé,
l'app essaie 47320, 47321… (20 essais). Si l'occupant est un autre Claude Pet, la nouvelle instance se ferme au lieu
d'afficher un second pet. Le port obtenu est publié dans `~/Library/Application Support/claude-pet/endpoint`
(`<port> <pid>`), et c'est là que les hooks le lisent : il n'y a rien à reconfigurer.

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

Chaque hook lit le fichier `endpoint` et vérifie que le pet est vivant (`kill -0 <pid>`), deux commandes internes au
shell qui ne lancent aucun processus. Ensuite seulement, il envoie le JSON stdin du hook avec
`curl -m 1 --connect-timeout 0.2`, puis sort toujours avec 0. Pet fermé : 0 à 10 ms, sans `curl`.

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

`POST /control` règle l'app : `{"notch": true}` ou `{"notch": false}` (avec l'animation), `notch_radius` et
`notch_ear` (rayons du cadre, en points).

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
