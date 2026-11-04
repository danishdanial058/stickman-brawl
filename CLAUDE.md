# Stickman Brawl: notes for Claude

A doodle-style stickman fighting game. It is one HTML file with all the CSS and JavaScript inline and a `<canvas>` for the fight. There is no build step and no npm, and the game uses no frameworks.

The owner is Danish (Didi). Explain changes simply, test them, then commit and push.

## The three builds (keep them in sync)

The same game lives in three files. **Every gameplay, UI or CSS change must be applied to all three**, usually with a small Python find-and-replace script that asserts each snippet matches exactly once per file.

| File | What it is | Differences |
|---|---|---|
| `index.html` | Android app (packed into the APK) | `<body class="app">`, local fonts from `fonts/` (added by the workflow), no-zoom viewport |
| `docs/index.html` | Website at https://brawl.expresslearn.my (GitHub Pages from `/docs`, `docs/CNAME`) | SEO/OG meta, manifest/icons, Google Fonts |
| `crazygames/index.html` | CrazyGames HTML5 build | Loads CrazyGames SDK v3; game code is wrapped in `window.__boot=()=>{…}` and started after `SDK.init()` |

Other web files: `docs/privacy.html` (privacy policy; contact `stickmanbrawl.support@gmail.com`, do not put the owner's personal email or GitHub on public pages), `docs/manifest.webmanifest`, icons, and the CrazyGames covers in `crazygames/`.

## Shipping

- **APK:** `.github/workflows/build-apk.yml` builds on every push to the app files. It creates the Android project inline (MainActivity is a full-screen WebView with system bars hidden) and publishes a GitHub release tagged `build-N` with `StickmanBrawl.apk`. `paths-ignore` skips server/, docs/, crazygames/, cloudflare/, render.yaml and this file.
- **Website:** pushing `docs/` updates GitHub Pages within a couple of minutes.
- **CrazyGames:** zip `crazygames/index.html`. The first submission was rejected for "overall quality", so the plan is to polish and resubmit later.
- `debug.keystore` is a public debug signing key. **Replace it with a private release key before any Play Store upload**, and never commit that key.

## Online play

- Host-authoritative over MQTT 3.1.1 on a WebSocket. The client in the game is the `Mqtt` class, topic prefix `sbx/v4` (`NET_PREFIX`).
- Main server: Cloudflare Worker + Durable Object (`cloudflare/src/index.js`, `wrangler.toml`), URL `wss://stickman-brawl.hackerrank.workers.dev/mqtt`. Backup: Render Node server (`server/server.js`, `render.yaml`) at `wss://stickman-brawl-server.onrender.com/mqtt`. Both accept the topic prefixes `sbx/` and `stickmanbrawl-dd058/`.
- Binary packets: snapshots start with `0xB4` (protocol v4, about 110 bytes, every 32 ms) and inputs with `0xB5`. The input flags byte holds l/r/b/j/d plus the dodge direction (32 = right, 64 = left). If you change the packet format, bump the protocol version and the topic prefix together.
- Everything received is untrusted: parse it defensively and clamp it (`num`, `okColor`, `cleanName`).
- Private rooms: "Invite a friend" (Online setup screen) makes a 6-character room. The room is its own matchmaking topic (`lobbyT()` → `r/<room>` instead of `lobby`). Invite links carry `?room=` (website/app) or the CrazyGames invite param `room`, and opening one joins that room at boot. On CrazyGames, `cgRoom()` calls `updateRoom`/`showInviteButton`/`hideInviteButton`/`leftRoom`, and `isInstantMultiplayer` opens a new room right away.
- Local testing: `?broker=ws://127.0.0.1:PORT/mqtt` makes the game use a local broker and also exposes `window.__netdbg.g`, the game state, for test scripts.

## Secrets

Keep API keys in `.env`, which git ignores (`.env.example` is the template), or in Cloudflare/Render secrets. **Never put a key in any of the HTML files.** Everything in them is public.

## Game code map (search these names in index.html)

- Logical canvas is 960x540 (`CFG.W/H`, `CFG.GROUND=452`). `render()` scales it to fit with "contain", and on wider screens it fills the sides with a mirrored, dimmed backdrop (keeps online play fair).
- Stages: `LAYOUTS`, `buildStage`, `placeStage`, `landOn`, `groundY`, `stageHazards`, `ringOut`, `respawn` (10 arenas with hazards: lava, spikes, conveyors, ice, moving platforms).
- Fighters: `Fighter` class, `TRAITS` + `applyTraits` (band, ninja, robo, champ, phantom, each with its own special: shadow, rocket, crown, haunt), ragdoll KO with the `Rag` class (Verlet).
- Weapons (10): `TOOL_IDS`, thrown weapons and `THROWN_IDS`, boomerang returns, bow fires arrows that stick.
- Effects: impact, arcs, bolts, craters, chunks, sparks, smoke, blast, shatter, trails. Online they are synced as events ('im','ar','bo','cr','bl','sh').
- Music: a sequencer with `SONGS`, `makeMelody`, `inst`, `drum`, `playStep`.
- UI screens: scrPlay, scrSetup, scrQuest, scrArmor, scrSettings, scrGuide, scrAch, results. Helpers `openScr`/`closeScr`/`backScr`. Quests are in `QSETS` (daily/weekly/monthly).
- Save: `save` object, `loadSave`/`writeSave` (localStorage, or CrazyGames data via `sGet`/`sSet`).
- Input: `P1KEYS`/`P2KEYS`, `hold`, `virt` (touch held state), `pressAct`, `fire`, `dirTap` (double-tap = dodge, `tapDir` gives the direction).
- Touch controls: `.pad` floats over the arena (see-through). Settings > Movement switches between the arrow buttons and a floating joystick (`save.ctl`, `joySet`/`joyReset`, body class `joy-on`).
- First-fight guide: `TIPS`, `tipMark`, `drawTips` (touch buttons and the joystick glow).
- CrazyGames hooks (`CG` is null elsewhere): `cgGameplay`, `cgBreakAd` (midgame ad before results, never online), muteAudio, username.

## Testing

- After editing, check the JavaScript parses: pull the biggest `<script>` out of each file and run `node --check` on it.
- Use Playwright (Python) for screenshots and to drive a match: Play, then the `button[data-m=versus]` mode, then `#fightBtn`. Use `has_touch=True` at phone sizes such as 915x412 and 412x915.

## Open ideas / to-do

- Dodge on the joystick needs a quick double flick. Options were offered: add a **Dodge button** and/or loosen the flick timing (the user hasn't chosen yet).
- Polish pass done (Nov 2026); resubmit to CrazyGames. Possible extra: leaderboard.
- Big Ink boss redesign, a cloud save transfer code, a release keystore for the Play Store.
