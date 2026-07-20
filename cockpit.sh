#!/usr/bin/env bash
# rclone cockpit v0 — a bash + gum TUI to manage remotes, mounts and bisyncs.
# Real state = rclone listremotes + plists in ~/Library/LaunchAgents + live mounts.
set -uo pipefail
shopt -s nullglob   # unmatched globs expand to nothing, not to the literal

RCLONE=/opt/homebrew/bin/rclone          # launchd's PATH != the shell's PATH
MOUNT_ROOT="$HOME/Drives"
SYNC_ROOT="$HOME/sync"
AGENTS="$HOME/Library/LaunchAgents"
VFS_CACHE="$HOME/Library/Caches/rclone/vfs"
LOGS="$HOME/Library/Logs/rclone-cockpit"
CONFIG_DIR="$HOME/.config/rclone-cockpit"
CONFIG="$CONFIG_DIR/config.env"

PREFIX_MOUNT="com.marlus.rclone-mount"
PREFIX_BISYNC="com.marlus.rclone-bisync"

# defaults, overridable via config.env
VFS_CACHE_MAX_SIZE="20G"
VFS_CACHE_MAX_AGE="72h"
# NFS tuning on macOS: long dir/attr caching cuts down the "Server connections
# interrupted" popups (the NFS client complains when the rclone server is busy
# re-scanning). poll-interval keeps remote change detection working.
DIR_CACHE_TIME="1000h"
ATTR_TIMEOUT="5s"
POLL_INTERVAL="15s"
# NFS client timeout in tenths of a second (60s). The macOS default is 1s
# (timeo=10); below ~60s any rclone response slower than that pops "Server
# connections interrupted". Verified applied via `nfsstat -m`.
NFS_TIMEO="600"
# log rotation (rclone-native): cap each log, keep a few gzipped backups
LOG_MAX_SIZE="10M"
LOG_MAX_BACKUPS="3"

# macOS junk that must not be pushed to the Drive by bisyncs (the local folder
# is a local disk, so DSDontWriteNetworkStores doesn't cover it — filter it here)
MAC_JUNK=(--exclude ".DS_Store" --exclude "._*" --exclude ".Spotlight-V100/**"
          --exclude ".Trashes/**" --exclude ".fseventsd/**" --exclude ".TemporaryItems/**")

# Skip files touched in the last minute. A big file still being copied into the
# folder would otherwise be uploaded half-written, then re-uploaded whole on the
# next run. Matters more with short intervals.
BISYNC_MIN_AGE="1m"

# selectable bisync intervals, as label:seconds
BISYNC_INTERVALS=("5min:300" "10min:600" "15min:900" "30min:1800" "1h:3600")

interval_labels() { local i; for i in "${BISYNC_INTERVALS[@]}"; do echo "${i%%:*}"; done; }
interval_secs()   { local i; for i in "${BISYNC_INTERVALS[@]}"; do [[ "${i%%:*}" == "$1" ]] && { echo "${i##*:}"; return; }; done; echo 1800; }
secs_label()      { local i; for i in "${BISYNC_INTERVALS[@]}"; do [[ "${i##*:}" == "$1" ]] && { echo "${i%%:*}"; return; }; done; echo "?"; }

mkdir -p "$CONFIG_DIR" "$LOGS"
[[ -f "$CONFIG" ]] && . "$CONFIG"

# ── helpers ───────────────────────────────────────────────────────────────────

die()  { gum style --foreground 1 "✗ $*"; }
ok()   { gum style --foreground 2 "✓ $*"; }
info() { gum style --foreground 4 "› $*"; }

header() {
  gum style --border rounded --padding "0 2" --border-foreground 4 "$*"
}

pause() { echo; gum style --faint "  ↵ press enter to go back"; read -r _; }

confirm() { gum confirm "$1"; }

remotes() { "$RCLONE" listremotes 2>/dev/null | sed 's/:$//'; }

is_mounted() {
  mount | grep -q " on ${MOUNT_ROOT}/$1 "
}

# a live nfsmount daemon for this remote (may exist even with no mount)
has_daemon() {
  pgrep -f "nfsmount $1:" >/dev/null 2>&1
}

# "zombie": the daemon is still serving NFS but the mount is gone from the
# mount table — this is the state macOS's "Server connections interrupted"
# leaves behind. Reading the mountpoint gives an empty folder, not an error.
is_zombie() {
  ! is_mounted "$1" && has_daemon "$1"
}

mount_state() {
  if is_mounted "$1";   then echo "mounted"
  elif has_daemon "$1"; then echo "zombie"
  else                       echo "—"
  fi
}

# kill the orphan daemon and mount again from scratch
repair_mount() {
  local r=$1
  info "killing the orphan daemon for $r ..."
  pkill -f "nfsmount $r:" 2>/dev/null
  sleep 2
  umount "$MOUNT_ROOT/$r" 2>/dev/null   # in case a stale mountpoint lingers
  has_daemon "$r" && { die "daemon did not die — try again"; return 1; }
  ok "daemon stopped"
  do_mount "$r"
}

plist_mount()  { echo "$AGENTS/${PREFIX_MOUNT}-$1.plist"; }
plist_bisync() { echo "$AGENTS/${PREFIX_BISYNC}-$1.plist"; }

has_autostart_mount()  { [[ -f "$(plist_mount "$1")" ]]; }
has_autostart_bisync() { [[ -f "$(plist_bisync "$1")" ]]; }

# list the configured bisync pairs (derived from the plists)
bisync_pairs() {
  local f base
  for f in "$AGENTS/${PREFIX_BISYNC}-"*.plist; do
    [[ -e "$f" ]] || continue
    base=$(basename "$f" .plist)
    echo "${base#${PREFIX_BISYNC}-}"
  done
}

# read a value stored in the plist (we use EnvironmentVariables as metadata)
plist_env() {
  /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$2" "$1" 2>/dev/null
}

launchctl_load() {
  launchctl bootstrap "gui/$(id -u)" "$1" 2>/dev/null \
    || launchctl load "$1" 2>/dev/null
}

launchctl_unload() {
  local label; label=$(basename "$1" .plist)
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null \
    || launchctl unload "$1" 2>/dev/null
  return 0
}

# ── remotes ───────────────────────────────────────────────────────────────────

menu_remotes() {
  while true; do
    clear; header "Accounts / remotes"
    local list; list=$(remotes)
    if [[ -z "$list" ]]; then
      info "no remotes configured yet"
    else
      while read -r r; do
        [[ -z "$r" ]] && continue
        local type; type=$("$RCLONE" config show "$r" 2>/dev/null | awk -F' = ' '/^type/{print $2}')
        printf "  %-20s %s\n" "$r" "${type:-?}"
      done <<< "$list"
    fi
    echo

    local action
    action=$(gum choose "Connect Google Drive" "Connect OneDrive" "Show usage (about)" "Remove remote" "← back") || return
    case "$action" in
      "Connect Google Drive") new_remote drive ;;
      "Connect OneDrive")     new_remote onedrive ;;
      "Show usage (about)")   remote_about ;;
      "Remove remote")        remove_remote ;;
      *) return ;;
    esac
  done
}

new_remote() {
  local type=$1 name
  name=$(gum input --placeholder "remote name (e.g. gdrive-personal)") || return
  [[ -z "$name" ]] && return
  if remotes | grep -qx "$name"; then die "remote '$name' already exists"; pause; return; fi

  info "opening OAuth in the browser — authorize and come back here"
  "$RCLONE" config create "$name" "$type" && ok "remote '$name' created" || die "failed"
  pause
}

remote_about() {
  local r; r=$(remotes | gum choose --header "which remote?") || return
  [[ -z "$r" ]] && return
  clear; header "$r"
  "$RCLONE" about "$r:" 2>&1
  echo; pause
}

remove_remote() {
  local r; r=$(remotes | gum choose --header "remove which?") || return
  [[ -z "$r" ]] && return
  confirm "remove '$r'? (its mounts/autostart will be turned off)" || return
  is_mounted "$r" && do_umount "$r"
  has_autostart_mount "$r" && autostart_mount_off "$r"
  "$RCLONE" config delete "$r" && ok "removed" || die "failed"
  pause
}

# ── mounts ────────────────────────────────────────────────────────────────────

# nfsmount (not 'mount'): on macOS it uses the native NFS server, no macFUSE.
# The Homebrew rclone build blocks 'mount' but allows 'nfsmount'.
mount_args() {
  local r=$1
  echo "nfsmount $r: $MOUNT_ROOT/$r \
--vfs-cache-mode full \
--vfs-cache-max-size $VFS_CACHE_MAX_SIZE \
--vfs-cache-max-age $VFS_CACHE_MAX_AGE \
--dir-cache-time $DIR_CACHE_TIME \
--attr-timeout $ATTR_TIMEOUT \
--poll-interval $POLL_INTERVAL \
-o timeo=$NFS_TIMEO \
--log-file $LOGS/mount-$r.log \
--log-file-max-size $LOG_MAX_SIZE \
--log-file-max-backups $LOG_MAX_BACKUPS \
--log-file-compress"
}

do_mount() {
  local r=$1
  mkdir -p "$MOUNT_ROOT/$r"
  # shellcheck disable=SC2046
  if ! "$RCLONE" $(mount_args "$r") --daemon; then   # --log-file is in mount_args
    die "failed to start the daemon (log: $LOGS/mount-$r.log)"; return 1
  fi
  # NFS server + OAuth can take a few seconds to show up in the mount table
  local i
  for i in $(seq 1 10); do
    is_mounted "$r" && { ok "mounted at ~/Drives/$r"; return 0; }
    sleep 1
  done
  die "started but did not appear in mount within 10s — see $LOGS/mount-$r.log"
}

do_umount() {
  local r=$1
  umount "$MOUNT_ROOT/$r" 2>/dev/null || diskutil unmount force "$MOUNT_ROOT/$r" >/dev/null 2>&1
  is_mounted "$r" && { die "still mounted"; return 1; }
  # the nfsmount daemon does NOT exit on umount — it keeps serving NFS with no
  # mount, i.e. a zombie. Kill it so the remote ends up truly unmounted.
  pkill -f "nfsmount $r:" 2>/dev/null
  local i; for i in 1 2 3 4 5 6; do has_daemon "$r" || break; sleep 0.5; done
  has_daemon "$r" && die "unmounted but daemon did not die" || ok "unmounted"
}

autostart_mount_on() {
  local r=$1 p; p=$(plist_mount "$r")
  mkdir -p "$MOUNT_ROOT/$r"
  cat > "$p" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PREFIX_MOUNT}-${r}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RCLONE}</string>
    <string>nfsmount</string>
    <string>${r}:</string>
    <string>${MOUNT_ROOT}/${r}</string>
    <string>--vfs-cache-mode</string><string>full</string>
    <string>--vfs-cache-max-size</string><string>${VFS_CACHE_MAX_SIZE}</string>
    <string>--vfs-cache-max-age</string><string>${VFS_CACHE_MAX_AGE}</string>
    <string>--dir-cache-time</string><string>${DIR_CACHE_TIME}</string>
    <string>--attr-timeout</string><string>${ATTR_TIMEOUT}</string>
    <string>--poll-interval</string><string>${POLL_INTERVAL}</string>
    <string>-o</string><string>timeo=${NFS_TIMEO}</string>
    <string>--log-file</string><string>${LOGS}/mount-${r}.log</string>
    <string>--log-file-max-size</string><string>${LOG_MAX_SIZE}</string>
    <string>--log-file-max-backups</string><string>${LOG_MAX_BACKUPS}</string>
    <string>--log-file-compress</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
  # if a manual mount is already running, launchd can't mount on top of it
  is_mounted "$r" && do_umount "$r" >/dev/null
  launchctl_load "$p" && ok "autostart enabled" || die "launchctl complained"
}

autostart_mount_off() {
  local r=$1 p; p=$(plist_mount "$r")
  launchctl_unload "$p"
  is_mounted "$r" && do_umount "$r" >/dev/null   # unmount before removing the plist
  rm -f "$p"
  ok "autostart disabled"
}

menu_mounts() {
  while true; do
    clear; header "Mounts  (~/Drives)"
    local list; list=$(remotes)
    if [[ -z "$list" ]]; then
      info "connect a remote first"; echo; pause; return
    fi
    local any_zombie=0
    while read -r r; do
      [[ -z "$r" ]] && continue
      local st auto
      st=$(mount_state "$r")
      [[ "$st" == "zombie" ]] && any_zombie=1
      has_autostart_mount "$r" && auto="[x] auto" || auto="[ ] auto"
      printf "  %-20s %-10s %s\n" "$r" "$st" "$auto"
    done <<< "$list"
    [[ "$any_zombie" == "1" ]] && { echo; die "zombie = daemon alive but mount gone (use 'repair')"; }
    echo

    local r; r=$(printf "%s\n← back\n" "$list" | gum choose --header "which remote?") || return
    [[ -z "$r" || "$r" == "← back" ]] && return

    local acts=()
    if is_zombie "$r"; then
      acts+=("repair (kill orphan daemon + remount)")
    elif is_mounted "$r"; then
      acts+=("unmount")
    else
      acts+=("mount")
    fi
    has_autostart_mount "$r" && acts+=("autostart: disable") || acts+=("autostart: enable")
    acts+=("← back")

    local a; a=$(printf '%s\n' "${acts[@]}" | gum choose --header "$r") || continue
    case "$a" in
      mount)                 do_mount "$r"; pause ;;
      unmount)               do_umount "$r"; pause ;;
      repair*)               repair_mount "$r"; pause ;;
      "autostart: enable")   autostart_mount_on "$r"; pause ;;
      "autostart: disable")  autostart_mount_off "$r"; pause ;;
    esac
  done
}

# ── bisync ────────────────────────────────────────────────────────────────────

bisync_run() {
  local pair=$1 extra=${2:-}
  local p; p=$(plist_bisync "$pair")
  local remote local_dir
  remote=$(plist_env "$p" COCKPIT_REMOTE)
  local_dir=$(plist_env "$p" COCKPIT_LOCAL)
  [[ -z "$remote" ]] && { die "could not find metadata for pair '$pair'"; return 1; }

  # interactive run: output to screen and log (launchd uses --log-file in the plist)
  # shellcheck disable=SC2086
  "$RCLONE" bisync "$remote" "$local_dir" $extra "${MAC_JUNK[@]}" \
    --create-empty-src-dirs --conflict-resolve newer --conflict-loser pathname \
    --min-age "$BISYNC_MIN_AGE" \
    -v --stats-one-line 2>&1 | tee -a "$LOGS/bisync-$pair.log"
  return "${PIPESTATUS[0]}"
}

# rclone refuses to sync and demands --resync in a few situations: an
# interrupted run, or a baseline taken while a side was empty. Detect it from
# the log so we can offer the fix instead of just reporting failure.
bisync_needs_resync() {
  tail -40 "$LOGS/bisync-$1.log" 2>/dev/null | grep -q "run --resync"
}

# Run a pair and, if rclone bails asking for a resync, offer to do it.
bisync_run_or_offer_resync() {
  local pair=$1
  clear; header "sync $pair"
  if bisync_run "$pair"; then ok "sync ok"; pause; return 0; fi

  if bisync_needs_resync "$pair"; then
    echo
    die "rclone aborted and needs a new baseline (--resync)"
    info "usual causes: a previous run was interrupted, or the baseline was"
    info "taken while one of the sides was still empty"
    echo
    if confirm "run --resync for '$pair' now?"; then
      clear; header "resync $pair"
      bisync_run "$pair" "--resync" && ok "baseline rebuilt — pair is in sync" \
        || die "resync failed — see $LOGS/bisync-$pair.log"
    fi
  else
    die "failed — see $LOGS/bisync-$pair.log"
  fi
  pause
}

# Write (or rewrite) a pair's plist in the current format. Used both when
# creating a pair and when changing its interval, so an old plist is upgraded
# in place instead of drifting from what new pairs get.
bisync_write_plist() {
  local pair=$1 remote_path=$2 local_dir=$3 secs=$4

  # <string> tags for the Mac junk excludes, so launchd runs the same as the TUI
  local junk_xml="" j
  for j in "${MAC_JUNK[@]}"; do junk_xml+="    <string>${j}</string>"$'\n'; done

  local p; p=$(plist_bisync "$pair")
  cat > "$p" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PREFIX_BISYNC}-${pair}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>COCKPIT_REMOTE</key><string>${remote_path}</string>
    <key>COCKPIT_LOCAL</key><string>${local_dir}</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>${RCLONE}</string>
    <string>bisync</string>
    <string>${remote_path}</string>
    <string>${local_dir}</string>
    <string>--create-empty-src-dirs</string>
    <string>--conflict-resolve</string><string>newer</string>
    <string>--conflict-loser</string><string>pathname</string>
    <string>--min-age</string><string>${BISYNC_MIN_AGE}</string>
${junk_xml}    <string>--log-file</string><string>${LOGS}/bisync-${pair}.log</string>
    <string>--log-file-max-size</string><string>${LOG_MAX_SIZE}</string>
    <string>--log-file-max-backups</string><string>${LOG_MAX_BACKUPS}</string>
    <string>--log-file-compress</string>
    <string>--log-level</string><string>INFO</string>
  </array>
  <key>StartInterval</key><integer>${secs}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOGS}/bisync-${pair}.out</string>
  <key>StandardErrorPath</key><string>${LOGS}/bisync-${pair}.out</string>
</dict>
</plist>
EOF
}

bisync_new() {
  local r; r=$(remotes | gum choose --header "source remote") || return
  [[ -z "$r" ]] && return

  info "listing folders in $r: ..."
  local dirs; dirs=$("$RCLONE" lsd "$r:" 2>/dev/null | awk '{ $1=$2=$3=$4=""; sub(/^ +/,""); print }')
  [[ -z "$dirs" ]] && { die "no folders in $r:"; pause; return; }

  local folder; folder=$(printf '%s\n' "$dirs" | gum choose --header "which folder?") || return
  [[ -z "$folder" ]] && return

  local pair; pair=$(echo "$folder" | tr ' /' '--' | tr '[:upper:]' '[:lower:]')
  pair=$(gum input --value "$pair" --placeholder "pair name (becomes ~/sync/<name>)") || return
  [[ -z "$pair" ]] && return
  has_autostart_bisync "$pair" && { die "pair '$pair' already exists"; pause; return; }

  local interval; interval=$(interval_labels | gum choose --header "interval") || return
  [[ -z "$interval" ]] && return
  local secs; secs=$(interval_secs "$interval")

  local remote_path="$r:$folder" local_dir="$SYNC_ROOT/$pair"
  mkdir -p "$local_dir"
  bisync_write_plist "$pair" "$remote_path" "$local_dir" "$secs"

  info "baseline: the first run needs --resync (may take a while)"
  if confirm "run --resync now?"; then
    clear; header "resync $pair"
    bisync_run "$pair" "--resync" && ok "baseline created" || die "resync failed — see $LOGS/bisync-$pair.log"
  fi

  if confirm "enable autostart ($interval)?"; then
    launchctl_load "$(plist_bisync "$pair")" && ok "scheduled every $interval" || die "launchctl complained"
  fi
  pause
}

# Change a pair's interval. Rewrites the plist in the current format (so old
# pairs also gain RunAtLoad/--min-age) and reloads the launchd job.
bisync_set_interval() {
  local pair=$1 p; p=$(plist_bisync "$pair")
  local remote_path local_dir cur
  remote_path=$(plist_env "$p" COCKPIT_REMOTE)
  local_dir=$(plist_env "$p" COCKPIT_LOCAL)
  cur=$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$p" 2>/dev/null)
  [[ -z "$remote_path" ]] && { die "could not read metadata for '$pair'"; pause; return 1; }

  local interval
  interval=$(interval_labels | gum choose --header "interval for '$pair' (now: $(secs_label "$cur"))") || return
  [[ -z "$interval" ]] && return
  local secs; secs=$(interval_secs "$interval")

  launchctl_unload "$p"
  bisync_write_plist "$pair" "$remote_path" "$local_dir" "$secs"
  if launchctl_load "$p"; then
    ok "'$pair' now runs every $interval (plist upgraded to the current format)"
  else
    die "plist rewritten but launchctl complained"
  fi
  pause
}

bisync_status() {
  local pair=$1 p; p=$(plist_bisync "$pair")
  clear; header "bisync: $pair"
  echo "  remote:   $(plist_env "$p" COCKPIT_REMOTE)"
  echo "  local:    $(plist_env "$p" COCKPIT_LOCAL)"
  echo "  interval: $(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$p" 2>/dev/null)s"
  local log="$LOGS/bisync-$pair.log"
  if [[ -f "$log" ]]; then
    echo "  last run: $(stat -f '%Sm' "$log")"
    echo; info "last lines:"; tail -8 "$log"
  else
    echo "  last run: never"
  fi
  local conflicts; conflicts=$(find "$(plist_env "$p" COCKPIT_LOCAL)" -name '*..conflict*' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$conflicts" != "0" ]] && die "$conflicts file(s) in conflict"
  echo; pause
}

bisync_remove() {
  local pair=$1 p; p=$(plist_bisync "$pair")
  local local_dir; local_dir=$(plist_env "$p" COCKPIT_LOCAL)
  confirm "disable pair '$pair'?" || return
  launchctl_unload "$p"
  rm -f "$p"
  ok "pair disabled"
  if [[ -d "$local_dir" ]] && confirm "delete the local folder $local_dir too?"; then
    rm -rf "$local_dir" && ok "folder deleted"
  fi
  pause
}

menu_bisync() {
  while true; do
    clear; header "Bidirectional  (~/sync)"
    local pairs; pairs=$(bisync_pairs)
    if [[ -z "$pairs" ]]; then
      info "no pairs configured"
    else
      while read -r pair; do
        [[ -z "$pair" ]] && continue
        local p; p=$(plist_bisync "$pair")
        local secs; secs=$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$p" 2>/dev/null)
        printf "  %-20s %-30s every %s\n" "$pair" "$(plist_env "$p" COCKPIT_REMOTE)" "$(secs_label "$secs")"
      done <<< "$pairs"
    fi
    echo

    local opts=("+ new pair")
    [[ -n "$pairs" ]] && while read -r pair; do [[ -n "$pair" ]] && opts+=("$pair"); done <<< "$pairs"
    opts+=("← back")

    local sel; sel=$(printf '%s\n' "${opts[@]}" | gum choose) || return
    case "$sel" in
      "+ new pair") bisync_new ;;
      "← back"|"") return ;;
      *)
        local a; a=$(gum choose --header "$sel" "status" "sync now" "dry-run" "resync (rebaseline)" "change interval" "disable" "← back") || continue
        case "$a" in
          status)                clear; bisync_status "$sel" ;;
          "sync now")            bisync_run_or_offer_resync "$sel" ;;
          "change interval")     bisync_set_interval "$sel" ;;
          dry-run)               clear; header "dry-run $sel"; bisync_run "$sel" "--dry-run"; pause ;;
          "resync (rebaseline)") confirm "rebuild baseline for '$sel'?" && { clear; bisync_run "$sel" "--resync" && ok "ok" || die "failed"; pause; } ;;
          disable)               bisync_remove "$sel" ;;
        esac
        ;;
    esac
  done
}

# ── logs & on-disk files ──────────────────────────────────────────────────────

# list the available logs as "mount:<remote>" / "bisync:<pair>"
log_sources() {
  local f base
  for f in "$LOGS"/mount-*.log; do
    base=$(basename "$f" .log); echo "mount:${base#mount-}"
  done
  for f in "$LOGS"/bisync-*.log; do
    base=$(basename "$f" .log); echo "bisync:${base#bisync-}"
  done
}

log_path_for() {  # "mount:gdrive" -> path to the .log
  local kind=${1%%:*} name=${1#*:}
  echo "$LOGS/$kind-$name.log"
}

# where files are materialized on disk for each source
disk_path_for() {
  local kind=${1%%:*} name=${1#*:}
  if [[ "$kind" == "bisync" ]]; then
    plist_env "$(plist_bisync "$name")" COCKPIT_LOCAL
  else
    echo "$VFS_CACHE/$name"       # VFS cache = what the mount downloaded to disk
  fi
}

view_disk_files() {
  local src=$1 dir; dir=$(disk_path_for "$src")
  clear; header "on-disk files — $src"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    info "nothing materialized on disk yet"
    [[ "${src%%:*}" == "mount" ]] && info "(a mount only downloads files when they are opened/read)"
    echo; pause; return
  fi
  echo "  local: $dir"
  echo "  total: $(du -sh "$dir" 2>/dev/null | cut -f1)"
  echo; info "files (by date, most recent first):"
  # list real files with size, sorted by mtime
  find "$dir" -type f ! -name '.*' -exec stat -f '%m %z %N' {} + 2>/dev/null \
    | sort -rn | head -40 \
    | while read -r mt sz path; do
        printf "  %6s  %s\n" "$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")" "${path#$dir/}"
      done
  echo; pause
}

menu_logs() {
  while true; do
    clear; header "Logs & files"
    local srcs; srcs=$(log_sources)
    if [[ -z "$srcs" ]]; then
      info "no logs yet — mount a drive or run a bisync"; echo; pause; return
    fi
    while read -r s; do
      [[ -z "$s" ]] && continue
      local lp; lp=$(log_path_for "$s")
      printf "  %-28s %s\n" "$s" "$(stat -f '%Sm' "$lp" 2>/dev/null)"
    done <<< "$srcs"
    echo

    local sel; sel=$(printf "%s\n← back" "$srcs" | gum choose --header "which source?") || return
    [[ -z "$sel" || "$sel" == "← back" ]] && return

    local a; a=$(gum choose --header "$sel" \
      "view log (paged)" "follow live (Ctrl-C to exit)" "on-disk files" "← back") || continue
    local lp; lp=$(log_path_for "$sel")
    case "$a" in
      "view log (paged)")
        if [[ -s "$lp" ]]; then gum pager < "$lp"; else clear; info "empty log"; pause; fi ;;
      "follow live (Ctrl-C to exit)")
        clear; header "$sel — live (Ctrl-C goes back)"
        ( trap 'exit 0' INT; tail -n 30 -f "$lp" ) ;;
      "on-disk files")
        view_disk_files "$sel" ;;
    esac
  done
}

# ── config / maintenance ──────────────────────────────────────────────────────

DS_KEY="DSDontWriteNetworkStores"

dsstore_hardened() {  # true if already =1
  [[ "$(defaults read com.apple.desktopservices "$DS_KEY" 2>/dev/null)" == "1" ]]
}

harden_dsstore() {
  clear; header "Block .DS_Store on network volumes"
  echo "  key: com.apple.desktopservices $DS_KEY"
  if dsstore_hardened; then
    ok "already hardened (=1)"
    echo; info "stops Finder from creating .DS_Store on NFS mounts (~/Drives)"
    echo; pause; return
  fi
  info "currently off — Finder creates .DS_Store on the mounts"
  echo
  confirm "apply (defaults write ... $DS_KEY -bool true)?" || return
  defaults write com.apple.desktopservices "$DS_KEY" -bool true
  if dsstore_hardened; then
    ok "hardened (=1)"
    info "takes effect after re-login. restarting Finder now helps:"
    if confirm "restart Finder now (killall Finder)?"; then
      killall Finder 2>/dev/null && ok "Finder restarted" || info "Finder was already restarting"
    fi
  else
    die "could not write the preference"
  fi
  pause
}

SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# count non-empty lines. grep -c already prints 0 for no match, but exits 1 —
# so never add a `|| echo 0` fallback here, it would print "0" twice.
count_lines() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }

# same, for lines matching a pattern
count_matching() { local n; n=$(grep -c "$2" "$1" 2>/dev/null); echo "${n:-0}"; }

# Scan a remote for .DS_Store into $2. Live count + elapsed, Ctrl-C cancels.
# Returns 130 if cancelled. The caller reads the count from the file.
dsstore_scan() {
  local r=$1 out=$2
  : > "$out"
  "$RCLONE" lsf -R --files-only --include ".DS_Store" "$r:" > "$out" 2>/dev/null &
  local pid=$! cancelled=0 i=0 start=$SECONDS
  # shellcheck disable=SC2064
  trap "cancelled=1; kill $pid 2>/dev/null" INT
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  %s scanning %s:  %s found · %ss   (Ctrl-C to cancel)\033[K" \
      "${SPIN_FRAMES[i++ % 10]}" "$r" "$(count_lines "$out")" "$((SECONDS - start))"
    sleep 0.2
  done
  trap - INT
  wait "$pid" 2>/dev/null
  printf "\r\033[K"
  [[ "$cancelled" == 1 ]] && return 130
  return 0
}

# Delete the .DS_Store of a remote showing "n/total done". Ctrl-C cancels
# (already-deleted files stay deleted — rclone has no transaction).
dsstore_delete() {
  local r=$1 total=$2 log=$3
  : > "$log"
  "$RCLONE" delete --include ".DS_Store" -v "$r:" > "$log" 2>&1 &
  local pid=$! cancelled=0 i=0 start=$SECONDS
  # shellcheck disable=SC2064
  trap "cancelled=1; kill $pid 2>/dev/null" INT
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  %s deleting in %s:  %s/%s · %ss   (Ctrl-C to cancel)\033[K" \
      "${SPIN_FRAMES[i++ % 10]}" "$r" "$(count_matching "$log" '\.DS_Store:')" \
      "$total" "$((SECONDS - start))"
    sleep 0.2
  done
  trap - INT
  wait "$pid" 2>/dev/null; local rc=$?
  printf "\r\033[K"
  [[ "$cancelled" == 1 ]] && return 130
  return "$rc"
}

clean_dsstore() {
  local r; r=$(remotes | gum choose --header "check/clean .DS_Store on which remote?") || return
  [[ -z "$r" ]] && return
  local tmp log
  tmp=$(mktemp); log=$(mktemp)
  clear; header ".DS_Store in $r:"

  if ! dsstore_scan "$r" "$tmp"; then
    info "scan cancelled"; rm -f "$tmp" "$log"; pause; return
  fi
  local n; n=$(count_lines "$tmp")
  if [[ "$n" -eq 0 ]]; then
    ok "no .DS_Store found 🎉"; rm -f "$tmp" "$log"; echo; pause; return
  fi

  die "$n .DS_Store file(s) on the Drive"
  echo; info "examples:"; head -10 "$tmp" | sed 's/^/  /'
  [[ "$n" -gt 10 ]] && echo "  ... (+$((n-10)))"
  echo
  if confirm "DELETE the $n .DS_Store in $r: from the cloud? (irreversible)"; then
    dsstore_delete "$r" "$n" "$log"
    local drc=$?
    [[ "$drc" == 130 ]] && info "cancelled — files already deleted stay deleted"
    # verify by rescanning
    if dsstore_scan "$r" "$tmp"; then
      local left; left=$(count_lines "$tmp")
      [[ "$left" -eq 0 ]] && ok "deleted — $r: is clean" || die "$left still remain"
    fi
  else
    info "nothing deleted"
  fi
  rm -f "$tmp" "$log"
  pause
}

menu_config() {
  while true; do
    clear; header "Config / maintenance"
    local st; dsstore_hardened && st="on ✓" || st="off ✗"
    printf "  .DS_Store network block: %s\n" "$st"
    echo
    local a; a=$(gum choose \
      "Block .DS_Store on network (DSDontWriteNetworkStores)" \
      "Check/clean .DS_Store on a remote" \
      "← back") || return
    case "$a" in
      "Block"*)       harden_dsstore ;;
      "Check/clean"*) clean_dsstore ;;
      *) return ;;
    esac
  done
}

# ── open in Finder ────────────────────────────────────────────────────────────

menu_finder() {
  local sel
  sel=$(gum choose --header "open in Finder" \
    "app config     ($CONFIG_DIR)" \
    "launchd plists ($AGENTS)" \
    "logs           ($LOGS)" \
    "rclone.conf    (~/.config/rclone)" \
    "mounts         ($MOUNT_ROOT)" \
    "sync           ($SYNC_ROOT)" \
    "← back") || return
  local dir
  case "$sel" in
    "app config"*)  dir="$CONFIG_DIR" ;;
    "launchd"*)     dir="$AGENTS" ;;
    "logs"*)        dir="$LOGS" ;;
    "rclone.conf"*) dir="$HOME/.config/rclone" ;;
    "mounts"*)      dir="$MOUNT_ROOT" ;;
    "sync"*)        dir="$SYNC_ROOT" ;;
    *) return ;;
  esac
  mkdir -p "$dir"
  open "$dir" && ok "opened $dir in Finder" || die "could not open $dir"
  sleep 1
}

# ── cache ─────────────────────────────────────────────────────────────────────

menu_cache() {
  clear; header "VFS cache"
  if [[ -d "$VFS_CACHE" ]]; then
    du -sh "$VFS_CACHE"/* 2>/dev/null | sed 's|'"$VFS_CACHE"'/|  |' || info "empty"
    echo
    echo "  total: $(du -sh "$VFS_CACHE" 2>/dev/null | cut -f1)"
  else
    info "no cache yet"
  fi
  echo
  if confirm "clear the cache? (only what is not in use)"; then
    rm -rf "${VFS_CACHE:?}"/* 2>/dev/null
    ok "cleared"
  fi
  pause
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
  command -v gum >/dev/null || { echo "gum not installed: brew install gum"; exit 1; }
  [[ -x "$RCLONE" ]] || { echo "rclone not found at $RCLONE"; exit 1; }

  while true; do
    clear
    gum style --border double --padding "1 4" --border-foreground 5 --align center \
      "rclone cockpit" "v0"
    echo
    local n_rem n_mnt n_bi
    n_rem=$(remotes | grep -c . || true)
    n_mnt=$(mount | grep -c " on ${MOUNT_ROOT}/" || true)
    n_bi=$(bisync_pairs | grep -c . || true)
    gum style --faint "  $n_rem remotes · $n_mnt mounted · $n_bi bisyncs"
    echo

    local c; c=$(gum choose "Accounts" "Mounts" "Bidirectional" "Logs" "Cache" "Config" "Open in Finder" "Quit") || exit 0
    case "$c" in
      Accounts)          menu_remotes ;;
      Mounts)            menu_mounts ;;
      Bidirectional)     menu_bisync ;;
      Logs)              menu_logs ;;
      Cache)             menu_cache ;;
      Config)            menu_config ;;
      "Open in Finder")  menu_finder ;;
      Quit|"")           clear; exit 0 ;;
    esac
  done
}

main "$@"
