package core

import (
	"os/exec"
	"strings"
)

// MountStatus is the derived state of a remote's mount.
type MountStatus int

const (
	// Unmounted: no mount and no serving daemon.
	Unmounted MountStatus = iota
	// Mounted: present in the mount table.
	Mounted
	// Zombie: the nfsmount daemon is alive and still serving NFS, but the mount
	// is gone from the mount table. macOS leaves this behind after "Server
	// connections interrupted"; the mountpoint reads as an empty folder rather
	// than erroring, so any check must test BOTH the mount table and the process.
	Zombie
)

func (s MountStatus) String() string {
	switch s {
	case Mounted:
		return "mounted"
	case Zombie:
		return "zombie"
	default:
		return "unmounted"
	}
}

// IsMounted reports whether the remote appears in the mount table at its
// expected mountpoint (~/Drives/<name>).
func (c *Client) IsMounted(name string) bool {
	out, err := exec.Command("mount").Output()
	if err != nil {
		return false
	}
	needle := " on " + c.Paths.MountRoot + "/" + name + " "
	return strings.Contains(string(out), needle)
}

// hasDaemon reports whether an `rclone nfsmount <name>:` process is alive.
func (c *Client) hasDaemon(name string) bool {
	// pgrep -f matches against the full command line; exit 0 means a match.
	return exec.Command("pgrep", "-f", "nfsmount "+name+":").Run() == nil
}

// MountState derives the tri-state for a remote.
func (c *Client) MountState(name string) MountStatus {
	switch {
	case c.IsMounted(name):
		return Mounted
	case c.hasDaemon(name):
		return Zombie
	default:
		return Unmounted
	}
}
