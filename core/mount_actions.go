package core

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// mountArgs builds the nfsmount argument list for a remote. nfsmount (not
// mount) is what works on the Homebrew rclone build on macOS: it starts the
// built-in NFS server, no macFUSE. Mirrors mount_args() in cockpit.sh.
func (c *Client) mountArgs(name string) []string {
	return []string{
		"nfsmount", name + ":", filepath.Join(c.Paths.MountRoot, name),
		"--vfs-cache-mode", "full",
		"--vfs-cache-max-size", vfsCacheSize,
		"--vfs-cache-max-age", vfsCacheAge,
		"--dir-cache-time", dirCacheTime,
		"--attr-timeout", attrTimeout,
		"--poll-interval", pollInterval,
		// Raise the NFS client timeout from the macOS default of 1s (timeo=10,
		// tenths of a second) to 60s. Below that, any rclone response slower
		// than a second (a scan, a dangling shortcut, client_id throttling)
		// makes macOS pop "Server connections interrupted". Verified applied
		// via `nfsstat -m`.
		"-o", "timeo=" + nfsTimeo,
		// Log to a rotated file here (not via --daemon/launchd stdout) so the
		// same rotation applies to a manual mount and to the autostart plist.
		"--log-file", c.mountLogPath(name),
		"--log-file-max-size", logMaxSize,
		"--log-file-max-backups", logMaxBackups,
		"--log-file-compress",
	}
}

// mountLogPath is where a remote's mount daemon logs (matches cockpit.sh).
func (c *Client) mountLogPath(name string) string {
	return filepath.Join(c.Paths.Logs, "mount-"+name+".log")
}

// Mount starts an nfsmount daemon for the remote and waits (up to ~10s) for it
// to appear in the mount table. The NFS server + OAuth can take a few seconds.
func (c *Client) Mount(name string) error {
	if err := os.MkdirAll(filepath.Join(c.Paths.MountRoot, name), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(c.Paths.Logs, 0o755); err != nil {
		return err
	}
	args := append(c.mountArgs(name), "--daemon") // --log-file is already in mountArgs
	if err := exec.Command(c.bin, args...).Run(); err != nil {
		return fmt.Errorf("start daemon: %w (see %s)", err, c.mountLogPath(name))
	}
	for i := 0; i < 10; i++ {
		if c.IsMounted(name) {
			return nil
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("mounted daemon started but did not appear in 10s (see %s)", c.mountLogPath(name))
}

// Unmount removes the mount AND kills the serving daemon. The nfsmount daemon
// does not exit when its mountpoint is unmounted — it keeps serving NFS with no
// mount, which is exactly the zombie state. So a correct unmount both drops the
// mount and stops the daemon, otherwise "unmount" would leave a zombie behind.
func (c *Client) Unmount(name string) error {
	target := filepath.Join(c.Paths.MountRoot, name)
	if c.IsMounted(name) {
		if exec.Command("umount", target).Run() != nil || c.IsMounted(name) {
			_ = exec.Command("diskutil", "unmount", "force", target).Run()
		}
	}
	if c.IsMounted(name) {
		return fmt.Errorf("%s still mounted", name)
	}
	// kill the now-orphan daemon so the remote ends up truly unmounted
	_ = exec.Command("pkill", "-f", "nfsmount "+name+":").Run()
	for i := 0; i < 6 && c.hasDaemon(name); i++ {
		time.Sleep(500 * time.Millisecond)
	}
	if c.hasDaemon(name) {
		return fmt.Errorf("%s unmounted but daemon did not die", name)
	}
	return nil
}

// Repair recovers a zombie: kills the orphan nfsmount daemon (which is still
// serving NFS with no mount) and mounts again from scratch. launchd's KeepAlive
// does not help here because the process never dies.
func (c *Client) Repair(name string) error {
	_ = exec.Command("pkill", "-f", "nfsmount "+name+":").Run()
	time.Sleep(2 * time.Second)
	_ = exec.Command("umount", filepath.Join(c.Paths.MountRoot, name)).Run() // clear any stale mountpoint
	if c.hasDaemon(name) {
		return fmt.Errorf("daemon for %s did not die", name)
	}
	return c.Mount(name)
}
