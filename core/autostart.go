package core

import (
	"encoding/xml"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// plistMountPath is the launchd plist for a remote's auto-mount.
func (c *Client) plistMountPath(name string) string {
	return filepath.Join(c.Paths.Agents, prefixMount+"-"+name+".plist")
}

// mountLabel is the launchd label (the plist basename without .plist).
func (c *Client) mountLabel(name string) string {
	return prefixMount + "-" + name
}

// HasAutostartMount reports whether a remote's auto-mount plist exists.
func (c *Client) HasAutostartMount(name string) bool {
	_, err := os.Stat(c.plistMountPath(name))
	return err == nil
}

// xmlStrings renders args as indented <string> plist tags, XML-escaped.
func xmlStrings(args []string) string {
	var b strings.Builder
	for _, a := range args {
		var esc strings.Builder
		_ = xml.EscapeText(&esc, []byte(a))
		fmt.Fprintf(&b, "    <string>%s</string>\n", esc.String())
	}
	return b.String()
}

// writeMountPlist writes the launchd plist. ProgramArguments is the rclone
// binary followed by the exact same args a manual mount uses (minus --daemon:
// launchd keeps the process in the foreground via KeepAlive).
func (c *Client) writeMountPlist(name string) error {
	if err := os.MkdirAll(c.Paths.Agents, 0o755); err != nil {
		return err
	}
	// rclone logs via --log-file (in mountArgs) with rotation, so there is no
	// StandardOutPath here — otherwise launchd would keep a second, unrotated log.
	args := append([]string{c.bin}, c.mountArgs(name)...)
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array>
%s  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
`, c.mountLabel(name), xmlStrings(args))
	return os.WriteFile(c.plistMountPath(name), []byte(plist), 0o644)
}

// AutostartMountOn enables auto-mount at login by writing the launchd plist.
// It deliberately does not mount now (see the comment inside): it is a boot
// preference and must leave the current mount state alone.
func (c *Client) AutostartMountOn(name string) error {
	if err := os.MkdirAll(filepath.Join(c.Paths.MountRoot, name), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(c.Paths.Logs, 0o755); err != nil {
		return err
	}
	// Only write the plist. A LaunchAgent placed in ~/Library/LaunchAgents is
	// loaded automatically at the next login, where RunAtLoad mounts it. We do
	// NOT launchctl-load it now: the daemon can't mount over a live manual mount,
	// so loading now would force an unmount/remount of whatever is mounted. This
	// is a preference ("mount at login"), so it must not disturb the current
	// mount. Use the Mount action to mount now.
	return c.writeMountPlist(name)
}

// AutostartMountOff removes the plist. If the launchd job is actually loaded
// (from a previous login), it is booted out and the mount cleaned up, since
// booting it out would otherwise leave the daemon's mount as a zombie. When the
// job was never loaded this session (the common case, because On doesn't load
// it), this only deletes the file and leaves the current mount untouched.
func (c *Client) AutostartMountOff(name string) error {
	if c.autostartLoaded(name) {
		launchctlUnload(c.mountLabel(name), c.plistMountPath(name))
		if c.IsMounted(name) || c.hasDaemon(name) {
			_ = c.Unmount(name)
		}
	}
	return os.Remove(c.plistMountPath(name))
}

// autostartLoaded reports whether the mount job is currently loaded in launchd
// (`launchctl list <label>` exits 0 only when the job exists).
func (c *Client) autostartLoaded(name string) bool {
	return exec.Command("launchctl", "list", c.mountLabel(name)).Run() == nil
}

// launchctlLoad loads a plist, preferring the modern bootstrap over load.
func launchctlLoad(path string) error {
	dom := fmt.Sprintf("gui/%d", os.Getuid())
	if exec.Command("launchctl", "bootstrap", dom, path).Run() == nil {
		return nil
	}
	return exec.Command("launchctl", "load", path).Run()
}

// launchctlUnload unloads a plist, preferring bootout over unload.
func launchctlUnload(label, path string) {
	svc := fmt.Sprintf("gui/%d/%s", os.Getuid(), label)
	if exec.Command("launchctl", "bootout", svc).Run() == nil {
		return
	}
	_ = exec.Command("launchctl", "unload", path).Run()
}
