# rclone cockpit

A TUI to manage a day-to-day [rclone](https://rclone.org) setup on macOS —
remotes, mounts and bisyncs — without hand-editing `plist` files or memorizing
flags. The "Google Drive checkbox": see the state and toggle things
interactively.

Built for a multi-cloud setup (2 Google Drives + OneDrive) where everything is
otherwise loose CLI invocations plus launchd files scattered around.

## All your clouds in one place, and a Mac that stays lean

Two Google Drives and a OneDrive — mounted, synced and scheduled from a single
terminal screen. No Google Drive for Desktop, no OneDrive app, no pair of
background daemons fighting for your menu bar, no auto-updaters, no telemetry.

**Lean is the point.** Mounted remotes behave like local folders while your SSD
only ever holds a bounded cache — browse terabytes, spend gigabytes. When you do
want files on disk, a bisync pair gives you a real local copy that works offline,
and you choose exactly which folders deserve it. Nothing is downloaded because
some vendor decided it should be.

**Nothing exotic underneath.** Scheduling is launchd, mounting is macOS's own NFS
client via rclone's built-in server. No macFUSE, no kernel extensions, no daemon
of its own — and the whole thing is one readable shell script. The state lives in
`rclone.conf` and in plain launchd plists, so you can inspect, edit or undo any
of it by hand, with or without this tool.

- **v0** — `cockpit.sh`, a bash + [gum](https://github.com/charmbracelet/gum) script. Working.
- **v1** (planned) — a Go **menu-bar app** plus a Go **TUI**, both thin front-ends
  over one shared, UI-agnostic `core` package.

**Everything lives side by side over one model.** No front-end is a replacement.
They all read the same source of truth (`rclone listremotes` + the launchd
plists + `mount`), so the shell version stays a first-class, supported entry
point — the dependency-light one that works over SSH, in a recovery shell, or
when you just want to read what it is about to do before it does it. Any
behaviour change lands in the shared core; no front-end invents state the others
cannot see.

---

## Requirements

- macOS 14+ (Apple Silicon) — mounts use the **native NFS server, no macFUSE**
- [Homebrew](https://brew.sh)
- rclone 1.68+ · gum (v0)
- For v1: the Go toolchain (managed with [mise](https://mise.jdx.dev)) and the
  Xcode Command Line Tools (cgo). The Go version is pinned in `mise.toml`.

```bash
brew install rclone gum
mise install          # installs the Go version pinned in mise.toml (v1 only)
```

## Running

```bash
git clone git@github.com:marlus/rclone-cockpit.git ~/Dev/rclone-cockpit
cd ~/Dev/rclone-cockpit
./cockpit.sh
```

Smoke test:

```bash
rclone version        # 1.68+
rclone listremotes    # may be empty
gum --version         # gum ok
```

---

## What it does (v0)

The main menu shows `N remotes · N mounted · N bisyncs` and opens these sections:

### Accounts
Connect **Google Drive** / **OneDrive** (triggers the OAuth flow in the browser
on first use), show usage (`rclone about`), remove a remote (unmounts and clears
its autostart along the way).

### Mounts (`~/Drives/<remote>`)
Lists each remote with its state (`mounted / zombie / —`) and `[x] auto`. Actions:
- **Mount / unmount** — via `rclone nfsmount`, with `--vfs-cache-mode full`.
- **Repair** — shown when a remote is in the `zombie` state (see below): kills
  the orphan daemon and mounts again from scratch.
- **Autostart** — on = writes a launchd `plist` (`RunAtLoad` + `KeepAlive`) and
  loads it; off = unloads and removes the `plist`.

### Bidirectional (`~/sync/<pair>`)
Two-way sync with `rclone bisync`:
- Browse the remote's folders (`rclone lsd`) and pick one.
- The first run performs a `--resync` (baseline).
- **Interval** of 5min, 10min, 15min, 30min or 1h (launchd's `StartInterval`),
  plus `RunAtLoad` so it also syncs when the agent loads (login/reboot) instead
  of waiting a whole interval.
- Per pair: status (last sync, conflicts), sync now, dry-run, rebaseline,
  **change interval**, disable (optionally deleting the local folder).
- Changing the interval rewrites the plist in the current format, so pairs
  created by an older version are upgraded in place (they gain `RunAtLoad` and
  `--min-age` too) rather than drifting from what new pairs get.

**It is not realtime.** bisync is a batch job: it wakes up, lists both sides,
transfers, and sleeps. Between runs it is blind — unlike the native Google Drive
app, which keeps a local file watcher and a push connection to the API. Use a
mount if you need live behaviour.

**Large files.** A big file still being copied into the folder would be uploaded
half-written and then re-uploaded whole on the next run. To avoid that, bisync
runs with `--min-age 1m`: files touched in the last minute are skipped and picked
up on the following run. The trade-off is a small delay — with a 5min interval,
worst case is roughly 6min from save to cloud. Two more things worth knowing:
launchd never runs two copies of the same job, so an upload that takes longer
than the interval simply delays the next run instead of overlapping it; and a
bisync interrupted mid-transfer (sleep, network drop, reboot) leaves the listings
inconsistent and will demand a **rebaseline** — a longer transfer means a wider
window for that to happen.

### Logs & files
Per source (mount or bisync):
- **View log**, paged.
- **Follow live** (`tail -f`, Ctrl-C goes back).
- **On-disk files** — what is materialized locally, with size and date (for a
  bisync = `~/sync/<pair>`; for a mount = the downloaded VFS cache).

Logs are rotated by rclone itself (`--log-file-max-size 10M`,
`--log-file-max-backups 3`, `--log-file-compress`), so a 24/7 mount does not grow
its log without bound — each service is capped at ~10M plus a few gzipped
backups. Rotation only works via `--log-file`, so mounts log there rather than
through launchd's `StandardOutPath`.

### Cache
`du -sh` of the VFS cache per remote, plus a clear action.

### Config / maintenance
- **Block `.DS_Store` on network** — checks and applies `DSDontWriteNetworkStores`
  (optionally restarting Finder).
- **Check/clean `.DS_Store` on a remote** — recursive search, shows how many
  exist and deletes them from the cloud only after confirmation.

### Open in Finder
Opens any of the app's folders in Finder: config, launchd plists, logs,
`rclone.conf`, `~/Drives`, `~/sync`.

---

## Mount vs bisync — which to use

They solve different problems and compose well:

|                | **Mount** (`~/Drives`)                  | **Bisync** (`~/sync`)                    |
|----------------|-----------------------------------------|------------------------------------------|
| Where files live | In the cloud; only what you open is cached locally | A full real copy on local disk        |
| Offline        | Only what is already cached             | Everything in that folder                |
| Disk usage     | Nearly none (bounded cache)             | Full size of the folder                  |
| Speed          | Depends on the network                  | Local-disk speed                         |
| Freshness      | Live                                    | Every 1h / 30min                         |
| Best for       | Browsing the whole archive              | Hot working folders, offline use, picky apps (editors, `git`, Lightroom) |

Rule of thumb: **mount** the whole archive, **bisync** the one or two folders you
actively work in. Bisync's costs are disk space, non-real-time sync, and the
chance of conflicts if the same file is edited on both sides between runs.

---

## `.DS_Store` on Google Drive

Finder creates `.DS_Store` in every folder you open, and they end up on the
Drive. There are **two distinct paths**, handled separately:

**1. Mounts (`~/Drives`, an NFS volume).** Stop Finder from writing `.DS_Store`
on network volumes:

```bash
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
```

> Takes effect **after re-login** (logout/login or reboot) — Finder reads this
> preference at login. To revert:
> `defaults delete com.apple.desktopservices DSDontWriteNetworkStores`.

**2. Bisyncs (`~/sync`, a local disk).** The default above does **not** cover
local disks, so `.DS_Store` is filtered in `rclone bisync` itself — via the
`MAC_JUNK` list in `cockpit.sh`, applied both in the TUI and in the launchd
`plist`:

```
--exclude .DS_Store  --exclude ._*  --exclude .Spotlight-V100/**
--exclude .Trashes/** --exclude .fseventsd/** --exclude .TemporaryItems/**
```

**Cleaning up the ones already uploaded.** In the TUI: **Config → Check/clean
`.DS_Store` on a remote** (searches, shows the count, deletes only after
confirmation). By hand:

```bash
rclone lsf -R --files-only --include ".DS_Store" gdrive-personal: | wc -l  # how many
rclone delete --include ".DS_Store" gdrive-personal:                       # delete
```

---

## How it works

- **State is derived, not stored.** The source of truth is `rclone listremotes`
  plus the `plist` files in `~/Library/LaunchAgents/com.marlus.rclone-*` plus the
  output of `mount`. There is no database of its own — only a `config.env` for
  defaults. A bisync's metadata (remote and local folder) lives in its own
  `plist`, under `EnvironmentVariables` (`COCKPIT_REMOTE` / `COCKPIT_LOCAL`).
- **launchd is the scheduler** (not cron, not a custom daemon). One `plist` per
  service: `com.marlus.rclone-mount-<remote>` and
  `com.marlus.rclone-bisync-<pair>`.
- **`rclone.conf` is never touched** by the app — the OAuth tokens are rclone's
  business.

### Fixed paths

| what    | where                                         |
|---------|-----------------------------------------------|
| mounts  | `~/Drives/<remote>`                           |
| bisyncs | `~/sync/<pair>`                               |
| plists  | `~/Library/LaunchAgents/com.marlus.rclone-*`  |
| logs    | `~/Library/Logs/rclone-cockpit/`              |
| cache   | `~/Library/Caches/rclone/vfs/`                |
| config  | `~/.config/rclone-cockpit/config.env`         |

---

## Known gotchas

- **Mounting on macOS uses `rclone nfsmount`, not `rclone mount`.** The Homebrew
  rclone build blocks `mount` on macOS ("not supported ... installed via
  Homebrew"); `nfsmount` works in that same build — it starts rclone's built-in
  NFS server and mounts it through the native `mount -t nfs`, with no macFUSE.
- **macOS's "Server connections interrupted" popup, and the `zombie` state.**
  The NFS client gives up on the rclone server (typically while it is busy
  re-scanning the Drive) and drops the mount, but the `rclone nfsmount` daemon
  keeps running and serving NFS. The result is a **zombie**: the process is
  alive, the mount is gone from the mount table, and `~/Drives/<remote>` reads as
  an empty folder rather than erroring. No data is lost — but the mount really is
  down, so it is not merely cosmetic. Detected by the Mounts screen and fixed by
  **repair** (kills the daemon, remounts). Note that launchd's `KeepAlive` does
  **not** cover this case: the process never dies, so there is nothing for
  launchd to restart.
  The main driver is the NFS client timeout: macOS mounts with `timeo=10` (1s,
  in tenths of a second — check with `nfsstat -m`), so any rclone response
  slower than a second trips the popup. Mounts are made with `-o timeo=600`
  (60s), which all but eliminates the "interrupted during a slow operation"
  case. Larger `--dir-cache-time` / `--attr-timeout` / `--poll-interval` help
  too. What remains is the genuine "the daemon went away" popup (on unmount,
  crash, or sleep) — there the server really is gone, and only macFUSE would
  avoid NFS entirely.
- **A bisync interrupted midway** requires `--resync` to rebuild the baseline —
  that is what the "rebaseline" action is for.
- **`Empty prior Path1 listing. Cannot sync to an empty directory`** — this hits
  when the baseline was taken while one side was still empty (e.g. you create the
  pair, let it resync against an empty folder, and only then drop files in).
  rclone refuses to proceed as a safeguard against mass deletion and demands a
  `--resync`. "sync now" detects this and offers the rebaseline directly. To
  avoid it: put the files in place *before* taking the baseline.
- **launchd's PATH differs from the shell's** — hence the binary is hardcoded to
  `/opt/homebrew/bin/rclone` in the plists.
- **Unloading a plist while its process runs**: unmount first.
- **`This remote uses rclone's shared Google Drive client_id`** — rclone ships a
  generic OAuth client_id so you can use it without registering your own. Google
  enforces API quota *per client_id*, so every rclone user who never configured
  one shares a single quota; that shared client is being retired and **stops
  working during 2026**. Until then it also costs throttling (403/429 + retries),
  which shows up as slow Drive scans and, indirectly, as the NFS server being
  busy enough to trigger the popup above. The fix is a personal client_id — see
  the roadmap entry below.

---

## Planned: personal OAuth client_id

**Why it is not optional:** rclone's shared Google Drive client_id is being
retired and stops working during 2026 — after that, Drive remotes fail to
authenticate. A personal client_id is free, takes ~10 minutes, and one is enough
for every Drive remote.

Getting the credentials (Google Cloud Console): create a project → enable the
**Google Drive API** → configure the OAuth consent screen → create an OAuth
client of type **Desktop app** → copy the client id and secret.

> **The trap:** on the consent screen, if the app is left in **Testing** status,
> refresh tokens expire after **7 days** and you must reauthorize weekly. It has
> to be **published** (*In production*). No Google review is needed, since the
> data belongs to the same account.

Applying them: `rclone config update <remote> client_id <id> client_secret
<secret>`, then reauthorize (`rclone config reconnect <remote>:`).

**To implement in the TUI** — *Config → Set custom client_id*:
- pick a remote, read the current value to show whether it is already set
- prompt with `gum input` for the id and `gum input --password` for the secret,
  so the secret never lands on screen or in a log
- call `rclone config update`, then offer to reauthorize
- offer to apply the same credentials to the other remotes of the same type
- never accept these values as CLI arguments (they would leak into shell
  history and the process list)

## Roadmap (v1, Go)

### Shape: one core, two front-ends

A single UI-agnostic **`core`** Go package holds all the logic — the same derived
state `cockpit.sh` computes today (`listremotes` + plists + `mount`), plus
mount/unmount, bisync runs, and the zombie detection. It exposes plain Go types
and knows nothing about any UI. `cockpit.sh` is effectively the executable spec
for what `core` must reproduce. Two thin front-ends sit on top:

- **`cmd/menubar`** — the primary v1 surface: a macOS status-bar app showing live
  state (reactive icon + text: mounted / unmounted / syncing / zombie), a
  dropdown of toggles, and native notifications for conflicts and zombie repair.
- **`cmd/tui`** — a terminal UI with [Bubble Tea](https://github.com/charmbracelet/bubbletea)
  (`list` / `checkbox` / `spinner`), for the SSH / no-GUI case.

### Menu-bar library decision

Chosen: **[caseymrm/menuet](https://github.com/caseymrm/menuet)** — verified active
in 2026 (v2.9.0). It is the only option that natively covers all three hard
requirements at once: **styled dynamic menu-bar text** (not just an icon),
submenus with checkmarks, and built-in native notifications. Runner-up if
cross-platform ever matters: `energye/systray` + `gen2brew/beeep`. Rejected:
**Fyne** (its tray shows an icon only, no menu-bar text) and **gogpu/systray**
(no-cgo and appealing, but v0.1.x and too green). Costs to accept: macOS-only,
cgo required, and notifications need a signed `.app` bundle with `LSUIElement`
(wanted anyway for a menu-bar utility).

### Features on top of that

- **Live IN⇄OUT sync monitor** (like the native Google Drive apps), reading
  rclone's remote-control API: start mounts/bisyncs with `--rc --rc-addr` and
  poll `core/stats` / `core/transferred` to render active transfers with speed
  and progress — surfaced as menu-bar text and a detail view.
- A sleep/wake hook to remount automatically after the Mac wakes up.
- A watchdog for the `zombie` state (poll mount + daemon, auto-repair) so it
  never needs a manual **repair**.
- A personal OAuth client_id flow (see above).
- Support for other backends (S3 / Hetzner).
- Bisync conflict notifications (native, via the menu-bar app).

## Definition of done (v0)

One real session: connect the 3 remotes, mount all 3 with autostart, create 2
bisyncs (1h and 30min), reboot the Mac — and have everything come back on its
own.
