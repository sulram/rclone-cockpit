# rclone cockpit

A TUI to manage a day-to-day [rclone](https://rclone.org) setup on macOS —
remotes, mounts and bisyncs — without hand-editing `plist` files or memorizing
flags. The "Google Drive checkbox": see the state and toggle things
interactively.

Built for a multi-cloud setup (2 Google Drives + OneDrive) where everything is
otherwise loose CLI invocations plus launchd files scattered around.

- **v0** — `cockpit.sh`, a bash + [gum](https://github.com/charmbracelet/gum) script. Working.
- **v1** (planned) — Go + [Bubble Tea](https://github.com/charmbracelet/bubbletea) + Lip Gloss + Bubbles.

**The two live side by side.** v1 is not a replacement: it is a nicer UX layer
over the same model (same paths, same plists, same launchd services, same
derived state). The shell version stays a first-class, supported entry point —
it is the dependency-light one that works over SSH, in a recovery shell, or when
you just want to read what it is about to do before it does it. Any behaviour
change should land in both, and neither should invent state the other cannot
see.

---

## Requirements

- macOS 14+ (Apple Silicon) — mounts use the **native NFS server, no macFUSE**
- [Homebrew](https://brew.sh)
- rclone 1.68+ · gum (v0) · Go 1.22+ (v1)

```bash
brew install rclone gum
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
- **Interval** of 1h or 30min (via launchd's `StartInterval`).
- Per pair: status (last sync, conflicts), sync now, dry-run, rebaseline,
  disable (optionally deleting the local folder).

### Logs & files
Per source (mount or bisync):
- **View log**, paged.
- **Follow live** (`tail -f`, Ctrl-C goes back).
- **On-disk files** — what is materialized locally, with size and date (for a
  bisync = `~/sync/<pair>`; for a mount = the downloaded VFS cache).

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
  **repair** (kills the daemon, remounts). Larger `--dir-cache-time`,
  `--attr-timeout` and `--poll-interval` reduce how often it happens; removing it
  entirely would require macFUSE. Note that launchd's `KeepAlive` does **not**
  cover this case: the process never dies, so there is nothing for launchd to
  restart.
- **A bisync interrupted midway** requires `--resync` to rebuild the baseline —
  that is what the "rebaseline" action is for.
- **launchd's PATH differs from the shell's** — hence the binary is hardcoded to
  `/opt/homebrew/bin/rclone` in the plists.
- **Unloading a plist while its process runs**: unmount first.

---

## Roadmap (v1, Go + Bubble Tea)

- Rewrite in Go using `list` / `checkbox` / `spinner` (Bubbles).
- **Live IN⇄OUT sync monitor** (like the native Google Drive apps), reading
  rclone's remote-control API: start mounts/bisyncs with `--rc --rc-addr` and
  poll `core/stats` / `core/transferred` to render active transfers with speed
  and progress.
- A sleep/wake hook to remount automatically after the Mac wakes up.
- A watchdog for the `zombie` state (poll mount + daemon, auto-repair) so it
  never needs a manual **repair**.
- Support for other backends (S3 / Hetzner).
- Bisync conflict notifications via `osascript`.

## Definition of done (v0)

One real session: connect the 3 remotes, mount all 3 with autostart, create 2
bisyncs (1h and 30min), reboot the Mac — and have everything come back on its
own.
