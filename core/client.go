package core

import (
	"bufio"
	"os/exec"
	"strings"
)

// Client is the entry point to all operations. It is safe to create many; it
// holds no mutable state (all state is read from the system on demand).
type Client struct {
	Paths Paths
	bin   string
}

// New returns a Client using the default paths and the pinned rclone binary.
func New() *Client {
	return &Client{Paths: DefaultPaths(), bin: rcloneBin}
}

// rclone runs the rclone binary with the given args and returns trimmed stdout.
// stderr is discarded here (rclone prints NOTICE/OAuth chatter there); callers
// that need it use rcloneCombined.
func (c *Client) rclone(args ...string) (string, error) {
	out, err := exec.Command(c.bin, args...).Output()
	return strings.TrimRight(string(out), "\n"), err
}

// Remote is a configured rclone remote.
type Remote struct {
	Name string
	Type string // "drive", "onedrive", ...
}

// ListRemotes returns the configured remotes with their backend type.
// Mirrors `rclone listremotes` + a type lookup per remote.
func (c *Client) ListRemotes() ([]Remote, error) {
	out, err := c.rclone("listremotes")
	if err != nil {
		return nil, err
	}
	var remotes []Remote
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		name := strings.TrimSuffix(strings.TrimSpace(sc.Text()), ":")
		if name == "" {
			continue
		}
		remotes = append(remotes, Remote{Name: name, Type: c.remoteType(name)})
	}
	return remotes, nil
}

// remoteType reads the backend type from `rclone config show <name>`.
// Returns "" if it cannot be determined.
func (c *Client) remoteType(name string) string {
	out, err := c.rclone("config", "show", name)
	if err != nil {
		return ""
	}
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		line := sc.Text()
		if k, v, ok := strings.Cut(line, " = "); ok && strings.TrimSpace(k) == "type" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
