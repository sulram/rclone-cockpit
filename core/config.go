// Package core holds all of rclone-cockpit's logic, with no dependency on any
// UI. Front-ends (the menu-bar app, the TUI) consume plain Go types from here.
//
// The design mirrors cockpit.sh: state is derived, never stored. The source of
// truth is `rclone listremotes` + the launchd plists + the live `mount` table.
package core

import (
	"os"
	"path/filepath"
)

// Fixed locations, matching cockpit.sh exactly so both front-ends and the shell
// version operate on the same files.
const (
	rcloneBin    = "/opt/homebrew/bin/rclone" // launchd's PATH != the shell's
	prefixMount  = "com.marlus.rclone-mount"
	prefixBisync = "com.marlus.rclone-bisync"
	bisyncMinAge = "1m"
	dirCacheTime = "1000h"
	attrTimeout  = "5s"
	pollInterval = "15s"
	vfsCacheSize = "20G"
	vfsCacheAge  = "72h"
	nfsTimeo     = "600" // NFS client timeout, tenths of a second (60s)
)

// Paths resolves the fixed directories relative to the user's home.
type Paths struct {
	Home      string
	MountRoot string // ~/Drives
	SyncRoot  string // ~/sync
	Agents    string // ~/Library/LaunchAgents
	VFSCache  string // ~/Library/Caches/rclone/vfs
	Logs      string // ~/Library/Logs/rclone-cockpit
	ConfigDir string // ~/.config/rclone-cockpit
}

// DefaultPaths returns the standard layout rooted at the current user's home.
func DefaultPaths() Paths {
	home, _ := os.UserHomeDir()
	return Paths{
		Home:      home,
		MountRoot: filepath.Join(home, "Drives"),
		SyncRoot:  filepath.Join(home, "sync"),
		Agents:    filepath.Join(home, "Library", "LaunchAgents"),
		VFSCache:  filepath.Join(home, "Library", "Caches", "rclone", "vfs"),
		Logs:      filepath.Join(home, "Library", "Logs", "rclone-cockpit"),
		ConfigDir: filepath.Join(home, ".config", "rclone-cockpit"),
	}
}
