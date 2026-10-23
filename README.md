# Claude Pet

Un petit compagnon en pixel-art qui vit par-dessus le bureau macOS et réagit à ce que fait Claude Code
(CLI `claude` et onglet Code de Claude Desktop), via les hooks de Claude Code.

```
Claude Code ──hook──▶ curl POST 127.0.0.1:47319/event ──▶ ClaudePet.app ──▶ sprite
```

## Installer

Ouvre `ClaudePet.dmg` et glisse **Claude Pet** dans Applications, puis lance-le depuis Applications. Au premier
lancement, un écran détaille tout ce qui va être installé (les hooks dans `~/.claude/settings.json`, le relais de la
ligne de statut, quelques fichiers dans `~/Library/Application Support/claude-pet/`). **Accepter** installe tout et
démarre le pet, directement dans l'encoche si ton Mac en a une ; **Refuser** ferme l'app sans rien écrire, et l'écran reviendra au prochain lancement. Avant toute
écriture, `settings.json` est copié : la copie d'origine (avant Claude Pet) et celle d'avant la dernière
modification peuvent être remises depuis Réglages › Claude Code.

Le DMG n'est pas encore signé par un développeur identifié ni notarisé : sur un autre Mac, macOS bloquera l'app
(Réglages système › Confidentialité et sécurité › « Ouvrir quand même »).

## Lancer depuis les sources

Il faut macOS 13+ et Swift 5.10+ (les Command Line Tools suffisent, pas besoin de Xcode).

```bash
swift run ClaudePet
scripts/make-dmg.sh          # construit build/ClaudePet.dmg
```

Le pet apparaît en bas à droite, et sa silhouette dans la barre des menus. Un clic sur celle-ci ouvre un panneau :
le pet animé et ce que fait Claude, les trois jauges d'utilisation, deux réglages rapides (**Afficher le pet**,
**Vivre dans l'encoche**), l'état du serveur, **Réglages…** (⌘,) et **Quitter** (⌘Q). Échap ou un clic ailleurs le referme. La fenêtre de réglages regroupe : afficher le pet, l'encoche,
la taille, le coin de l'écran, les quotas du compte, l'état des hooks (réparer, réinstaller, désinstaller) et la
restauration des copies de `settings.json`. Glisse le pet à la souris : sa position est mémorisée. Un clic droit sur
le pet ouvre un menu avec les réglages essentiels.
L'interface est en français si macOS est en français, en anglais sinon (la langue choisie pour Claude Pet
dans Réglages système › Langue et région est respectée).

### Mode encoche

Sur un MacBook à encoche, active **Vivre dans l'encoche** (panneau de la barre des menus, ou ⌘N dans le clic droit). Le pet s'accroupit, s'envole vers
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

Quand tu survoles l'encoche, trois anneaux apparaissent autour du pet pendant que le cadre s'agrandit : **bleu** en bas
à gauche pour le quota 5 h, **violet** en bas à droite pour le quota de la semaine, **vert** en haut à droite pour la
fenêtre de contexte de la session suivie. Chacun affiche son pourcentage. Replié, le cadre ne montre que le pet. Passer sur un anneau affiche le détail (« Quota 5 h : 50 % ·
reset dans 2 h 04 »).

Aucune source officielle ne stocke ces chiffres. Le pet les lit en lecture seule, et la donnée la plus récente gagne :

| Source | Donne | Quand |
|---|---|---|
| API d'usage d'Anthropic (`api.anthropic.com/api/oauth/usage`), comme ccusage ou claude-hud | quotas 5 h et semaine, frais | partout, toutes les 5 min, si Claude Code est connecté (Pro/Max) |
| Ligne de statut de Claude Code (relais `statusline.sh`) | quotas 5 h et semaine, contexte exact | sessions `claude` dans un terminal (Desktop ne l'exécute pas) ; quotas pour Pro/Max, après la première réponse |
| `~/Library/Application Support/Claude/plan-usage-history.json` | quotas | quand Claude Desktop l'écrit (au plus toutes les 270 s ; parfois plus du tout) |
| Transcript de la session (chemin reçu avec chaque hook) | contexte estimé (« ≈ », taille de fenêtre supposée : 200k, ou 1M au-delà) | toutes les sessions, Desktop compris |

Une donnée trop vieille pour sa fenêtre, ou dont la fenêtre a été réinitialisée, est affichée comme inconnue (anneau
vide), jamais comme 0 %.

**L'API d'usage et ton Trousseau.** Pour l'API, l'app lit le jeton de connexion que Claude Code range dans le
Trousseau (« Claude Code-credentials »). macOS demande ton accord au premier accès. L'app étant signée localement, il le
redemandera sans doute après chaque recompilation. Le jeton reste en mémoire : il n'est jamais écrit, ni journalisé, ni
renouvelé par l'app elle-même. Les sessions de Claude Desktop ne renouvellent pas ce jeton (elles utilisent la
connexion de Desktop). S'il a expiré, l'app demande donc à Claude Code de le faire en lançant `claude -p /usage`, sans
hooks ni historique, au plus une fois toutes les 10 min. Cette commande n'envoie aucune requête au modèle et ne
consomme pas de quota (vérifié dans son journal de debug). La requête est un GET vers cette seule
adresse, sans redirection ni cookie, avec des pauses plus longues en cas d'erreur. Elle est désactivée par défaut (case de
l'écran d'accueil) ; on l'active ou la coupe dans Réglages › Données › **Quotas du compte**, où s'affiche aussi son état.
Le cookie de session claude.ai (endpoint `/usage` de Desktop) n'est, lui, jamais utilisé.

L'installation remplace la commande de ta ligne de statut par le relais, qui transmet le JSON au pet puis lance ta
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
- Pendant le drag, le pet s'incline selon sa vitesse horizontale. Un simple clic lui fait faire un petit rebond,
  puis il te fait coucou pendant 2,5 s, quoi que fasse Claude, avant de reprendre son état. S'il dormait, il se
  rendort 10 s plus tard s'il ne se passe rien.

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

L'app s'en charge (écran d'accueil, puis Réglages › Claude Code). Le script Python fait la même chose en ligne de
commande, pour le développement :

```bash
scripts/install-hooks.py install --dry-run   # montre le diff, n'écrit rien
scripts/install-hooks.py install             # montre le diff, demande confirmation, sauvegarde, écrit
scripts/install-hooks.py uninstall           # retire uniquement nos hooks
```

- L'installation fusionne dans `~/.claude/settings.json` sans toucher aux autres hooks (vibe-island, etc.). Nos entrées sont
  repérées par le commentaire `# claude-pet-hook`, ce qui rend `install` idempotent et `uninstall` propre.
- Avant d'écrire, elle copie le fichier dans `settings.json.claude-pet-backup-<date>` ; l'app garde en plus, une
  seule fois, `settings.json.claude-pet-original`.
- Les sessions Claude Code déjà ouvertes ne voient les nouveaux hooks qu'après redémarrage (ou via `/hooks`).

Chaque hook lit le fichier `endpoint` et vérifie que le pet est vivant (`kill -0 <pid>`), deux commandes internes au
shell qui ne lancent aucun processus. Ensuite seulement, il envoie le JSON stdin du hook avec
`curl -m 1 --connect-timeout 0.2`, puis sort toujours avec 0. Pet fermé : 0 à 10 ms, sans `curl`.

**Pourquoi un envoi synchrone et pas en arrière-plan ?** En arrière-plan, un gros `PostToolUse` (sortie d'un Read
de plusieurs Mo) arrivait *après* le `PreToolUse` suivant, et le pet affichait le mauvais état. En synchrone, Claude
Code attend la fin de chaque hook, donc l'ordre est garanti. Coût mesuré : ~10 ms par hook, ~30 ms pour 5 Mo,
quasi nul si l'app est fermée (connexion refusée), 1 s au pire si l'app est bloquée.

## Répondre à Claude depuis le pet

Quand Claude demande une permission (lancer une commande, modifier un fichier…) ou te pose une question
(`AskUserQuestion`), le pet te la montre et tu peux répondre sans retourner dans Claude.

- **Encoche** : un bandeau « Claude a besoin de vous » sort sous l'encoche. Au survol, il s'ouvre en panneau autour
  de l'encoche (à gauche, à droite et en dessous) avec la commande, le fichier ou la question, et les boutons. Le pet
  reste à sa place, à droite.
- **Flottant** : une pastille au-dessus du pet, qui s'ouvre en carte au survol ou au clic.
- Une fois la demande ouverte, le bandeau ou la pastille ne revient pas : seul le pet reste en alerte (main levée,
  « ! »). Survoler l'encoche, ou le pet en mode flottant, rouvre la demande. Une nouvelle demande refait apparaître
  le bandeau.
- Permission : **Autoriser** (une fois, jamais « toujours »), **Refuser** (Claude reçoit « Refusé par l'utilisateur
  depuis Claude Pet. ») ou **Ignorer** (tu réponds dans Claude). Questions : un clic choisit (cases à cocher puis
  **Valider** pour un choix multiple). **Autre** ouvre un champ pour taper ta propre réponse (Entrée pour valider) :
  le pet prend le clavier seulement pendant la saisie. **Ignorer** laisse faire dans Claude.

Claude Code affiche aussi son propre dialogue, questions comprises, et garde **la première réponse**, où qu'elle
soit : pet, terminal, Desktop ou une autre app comme Vibe Island. La demande disparaît alors du pet. Pet fermé ou
masqué : rien ne change, tout se passe dans Claude.

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
| au repos et aucun hook depuis 10 s | dort, image figée (aucune animation, quasiment aucun CPU) |

Garde-fous : un état « travaille » ou « réfléchit » sans événement depuis 10 min repasse au repos (un Échap
n'envoie pas de `Stop`), et une session muette depuis 3 h est oubliée.

### Plusieurs sessions

Le pet suit **la session dont l'état est le plus prioritaire** : t'attend > erreur > travaille > réfléchit > content >
au repos. En cas d'égalité, c'est la plus récemment active qui gagne. Une session qui a besoin de toi n'est donc jamais
masquée par une autre qui travaille. Le panneau de la barre des menus affiche le nombre de sessions suivies.

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
  les Spaces et en plein écran. Modes flottant / encoche et vol entre les deux. Il laisse passer les clics partout sauf sur les pixels opaques du
  sprite. La souris est suivie par événements quand elle est immobile, par relevés à 30 Hz quand elle bouge, sans
  permission Accessibilité. `scripts/measure-cpu.sh` mesure le CPU et la mémoire par état.
- `Sources/ClaudePet/EventServer.swift` : serveur HTTP minimal (Network.framework).
- `Sources/ClaudePet/ControlPanel.swift` : panneau de la barre des menus, dessiné à la main.
- `Sources/ClaudePet/SettingsWindow.swift`, `PanelKit.swift` : fenêtre de réglages et éléments dessinés partagés.
- `Sources/ClaudePet/OnboardingWindow.swift` : écran du premier lancement.
- `Sources/ClaudePet/HookSetup.swift` : installation, désinstallation et restauration des hooks, en Swift.
- `Sources/ClaudePet/AppDelegate.swift` : câblage, menu du clic droit.

Pourquoi un Swift Package plutôt qu'un projet Xcode : il se compile avec `swift build` sans Xcode, il n'y a pas de
fichier projet à maintenir, et `scripts/bundle.sh` suffit pour produire le `.app` (avec `LSUIElement`).
