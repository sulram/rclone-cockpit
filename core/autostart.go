package core

import (
	"encoding/xml"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
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

// AutostartMountOn writes the plist and loads it, so the mount comes up at login
// and is kept alive. A manual mount already running is dropped first, since
// launchd cannot mount on top of it.
func (c *Client) AutostartMountOn(name string) error {
	if err := os.MkdirAll(filepath.Join(c.Paths.MountRoot, name), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(c.Paths.Logs, 0o755); err != nil {
		return err
	}
	if err := c.writeMountPlist(name); err != nil {
		return err
	}
	if c.IsMounted(name) || c.hasDaemon(name) {
		_ = c.Unmount(name)
	}
	if err := launchctlLoad(c.plistMountPath(name)); err != nil {
		return err
	}
	// launchd starts the job asynchronously; wait for the mount to settle so
	// callers don't observe the transient daemon-up-but-not-mounted state
	// (which MountState would read as a zombie). KeepAlive keeps retrying
	// regardless, so a slow mount is not an error.
	for i := 0; i < 10 && !c.IsMounted(name); i++ {
		time.Sleep(time.Second)
	}
	return nil
}

// AutostartMountOff unloads the job, unmounts, and removes the plist.
func (c *Client) AutostartMountOff(name string) error {
	launchctlUnload(c.mountLabel(name), c.plistMountPath(name))
	if c.IsMounted(name) || c.hasDaemon(name) {
		_ = c.Unmount(name)
	}
	return os.Remove(c.plistMountPath(name))
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
