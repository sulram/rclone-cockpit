# rclone-cockpit

A TUI (Go / Charm ecosystem) to manage a day-to-day rclone setup — remotes,
mounts and bisyncs — without hand-editing plists. See [README.md](README.md) for
the overview, usage and roadmap.

- **v0**: `cockpit.sh` — bash + [gum](https://github.com/charmbracelet/gum).
- **v1** (planned): Go + Bubble Tea + Lip Gloss + Bubbles.

**v0 and v1 live side by side — v1 does NOT replace v0.** The Go version is a
cosmetic/UX layer over the same model: same paths, same plist names, same
launchd services, same derived state. The shell version stays first-class and
supported (dependency-light, works over SSH and in recovery shells). Practical
rules: never delete or deprecate `cockpit.sh`; land behaviour changes in both;
never introduce state in one that the other cannot read (the plists + `mount` +
`listremotes` remain the only source of truth).

## Running

```bash
./cockpit.sh          # v0
```

## Language

**Everything in this project is written in English** — code, identifiers,
comments, UI strings, documentation, README, commit messages, and issue/PR
titles and bodies. No exceptions.

## Technical conventions

- **State is derived, not stored**: the source of truth is `rclone listremotes`
  plus the plists in `~/Library/LaunchAgents/com.marlus.rclone-*` plus `mount`.
  There is no database of its own (only `config.env` for defaults). A bisync's
  metadata lives in its own plist, under `EnvironmentVariables`
  (`COCKPIT_REMOTE` / `COCKPIT_LOCAL`).
- **launchd is the scheduler** (not cron). One plist per service:
  `com.marlus.rclone-mount-<remote>` / `com.marlus.rclone-bisync-<pair>`.
- **Fixed paths**: mounts in `~/Drives/<remote>`, bisyncs in `~/sync/<pair>`,
  logs in `~/Library/Logs/rclone-cockpit/`, VFS cache in
  `~/Library/Caches/rclone/vfs/`.
- **rclone binary**: always `/opt/homebrew/bin/rclone` (launchd's PATH is not the
  shell's).
- **Mounting on macOS = `rclone nfsmount`, never `rclone mount`**: the Homebrew
  build blocks `mount` on macOS ("not supported ... installed via Homebrew"), but
  `nfsmount` works in that same build (it starts the built-in NFS server, no
  macFUSE).
- **The "Server connections interrupted" popup / `zombie` state**: the macOS NFS
  client drops the mount while the `rclone nfsmount` daemon keeps running. The
  mount vanishes from the mount table but the process is alive, and the
  mountpoint reads as an empty folder instead of erroring — so any check must
  test **both** `mount` and the process (`is_mounted` + `has_daemon`). Fixed by
  `repair_mount` (kill + remount). launchd `KeepAlive` does not help here, since
  the process never dies. Larger `--dir-cache-time`, `--attr-timeout` and
  `--poll-interval` reduce the frequency.
- **`.DS_Store` and Mac junk**: two fronts. (1) NFS mounts: `defaults write
  com.apple.desktopservices DSDontWriteNetworkStores -bool true` stops Finder
  from creating `.DS_Store` on network volumes (effective after re-login).
  (2) Bisyncs (local disk, not covered by that default): filtered in rclone via
  `MAC_JUNK` (`--exclude .DS_Store/._*/.Spotlight-V100` etc.), applied in
  `bisync_run` and in the launchd plist.

## Commits

- **Conventional Commits**, fully in **English**: type (`feat`, `fix`, `docs`,
  `chore`, `refactor`) and description in **imperative, lowercase**.
  E.g.: `feat: validate coupon per offer at checkout`.
- **Semantic Release** reads the types: `feat` → minor · `fix` → patch ·
  `BREAKING CHANGE` → major.
- **Never** add Claude as a co-author: no `Co-Authored-By` trailer and no
  "Generated with Claude Code" footer — in commits **and** PRs.
