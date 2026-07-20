package core

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// macJunk keeps macOS cruft out of bisyncs. The local side is a real disk, so
// DSDontWriteNetworkStores doesn't cover it — filter here (mirrors cockpit.sh).
var macJunk = []string{
	"--exclude", ".DS_Store", "--exclude", "._*",
	"--exclude", ".Spotlight-V100/**", "--exclude", ".Trashes/**",
	"--exclude", ".fseventsd/**", "--exclude", ".TemporaryItems/**",
}

// BisyncPair is a configured two-way sync, derived from its launchd plist.
type BisyncPair struct {
	Name        string
	Remote      string // e.g. "gdrive-tekne:TEST"
	Local       string // e.g. "~/sync/test"
	IntervalSec int
}

func (c *Client) plistBisyncPath(name string) string {
	return filepath.Join(c.Paths.Agents, prefixBisync+"-"+name+".plist")
}

func (c *Client) bisyncLogPath(name string) string {
	return filepath.Join(c.Paths.Logs, "bisync-"+name+".log")
}

// BisyncPairs lists the configured pairs, read from the launchd plists.
func (c *Client) BisyncPairs() []BisyncPair {
	paths, _ := filepath.Glob(filepath.Join(c.Paths.Agents, prefixBisync+"-*.plist"))
	var pairs []BisyncPair
	for _, p := range paths {
		if pair, err := c.readBisyncPlist(p); err == nil {
			pairs = append(pairs, pair)
		}
	}
	return pairs
}

// readBisyncPlist parses a bisync plist via `plutil -convert json`.
func (c *Client) readBisyncPlist(path string) (BisyncPair, error) {
	out, err := exec.Command("plutil", "-convert", "json", "-o", "-", path).Output()
	if err != nil {
		return BisyncPair{}, err
	}
	var d struct {
		Label         string `json:"Label"`
		StartInterval int    `json:"StartInterval"`
		Env           struct {
			Remote string `json:"COCKPIT_REMOTE"`
			Local  string `json:"COCKPIT_LOCAL"`
		} `json:"EnvironmentVariables"`
	}
	if err := json.Unmarshal(out, &d); err != nil {
		return BisyncPair{}, err
	}
	return BisyncPair{
		Name:        strings.TrimPrefix(d.Label, prefixBisync+"-"),
		Remote:      d.Env.Remote,
		Local:       d.Env.Local,
		IntervalSec: d.StartInterval,
	}, nil
}

// LastSync is the mtime of the pair's log (zero if it never ran).
func (c *Client) LastSync(name string) time.Time {
	fi, err := os.Stat(c.bisyncLogPath(name))
	if err != nil {
		return time.Time{}
	}
	return fi.ModTime()
}

// SyncNow runs one bisync for the pair. needsResync is true if rclone aborted
// asking for a --resync (interrupted run, or a baseline taken while empty).
func (c *Client) SyncNow(name string) (needsResync bool, err error) {
	return c.runBisync(name, false)
}

// Resync rebuilds the baseline (rclone bisync --resync).
func (c *Client) Resync(name string) error {
	_, err := c.runBisync(name, true)
	return err
}

func (c *Client) runBisync(name string, resync bool) (bool, error) {
	pair, err := c.readBisyncPlist(c.plistBisyncPath(name))
	if err != nil {
		return false, err
	}
	args := append([]string{"bisync", pair.Remote, pair.Local}, macJunk...)
	args = append(args,
		"--create-empty-src-dirs", "--conflict-resolve", "newer",
		"--conflict-loser", "pathname", "--min-age", bisyncMinAge,
		"--log-file", c.bisyncLogPath(name),
		"--log-file-max-size", logMaxSize, "--log-file-max-backups", logMaxBackups,
		"--log-file-compress", "--log-level", "INFO",
	)
	if resync {
		args = append(args, "--resync")
	}
	err = exec.Command(c.bin, args...).Run()
	if err != nil && !resync && c.bisyncNeedsResync(name) {
		return true, err
	}
	return false, err
}

// bisyncNeedsResync scans the tail of the log for rclone's resync demand.
func (c *Client) bisyncNeedsResync(name string) bool {
	out, _ := exec.Command("tail", "-40", c.bisyncLogPath(name)).Output()
	return strings.Contains(string(out), "run --resync")
}

// Open reveals a path in Finder.
func (c *Client) Open(path string) error {
	return exec.Command("open", path).Run()
}

// MountPath is a remote's mountpoint (~/Drives/<name>).
func (c *Client) MountPath(name string) string {
	return filepath.Join(c.Paths.MountRoot, name)
}
