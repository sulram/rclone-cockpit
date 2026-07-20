// Command menubar is the macOS status-bar front-end for rclone-cockpit.
// It renders live remote state from the shared core package and exposes the
// mount actions as clickable menu items.
package main

import (
	"fmt"
	"time"

	"github.com/caseymrm/menuet/v2"
	"github.com/sulram/rclone-cockpit/core"
)

var client = core.New()

// refresh repaints the menu-bar title and the open dropdown.
func refresh() {
	menuet.App().SetMenuState(title())
	menuet.App().MenuChanged()
}

// run executes a blocking core action off the UI thread, then refreshes.
// Actions like Mount wait up to ~10s, so they must not run on the AppKit
// run loop or the menu would freeze.
func run(action func() error) func() {
	return func() {
		go func() {
			_ = action()
			refresh()
		}()
	}
}

// title reflects overall state in the menu bar: cloud icon plus mounted count,
// turning warning-colored if any remote is in the zombie state.
func title() *menuet.MenuState {
	remotes, err := client.ListRemotes()
	if err != nil {
		return &menuet.MenuState{Title: "☁️ ?"}
	}
	mounted, zombie := 0, 0
	for _, r := range remotes {
		switch client.MountState(r.Name) {
		case core.Mounted:
			mounted++
		case core.Zombie:
			zombie++
		}
	}
	if zombie > 0 {
		return &menuet.MenuState{Runs: []menuet.TextRun{
			{Text: "☁️ "},
			{Text: fmt.Sprintf("%d⚠", zombie), Color: menuet.SystemOrange, FontWeight: menuet.WeightBold},
		}}
	}
	return &menuet.MenuState{Title: fmt.Sprintf("☁️ %d", mounted)}
}

// menu builds the dropdown: one row per remote, each opening a submenu with the
// action appropriate to its current state.
func menu() []menuet.MenuItem {
	items := []menuet.MenuItem{
		menuet.Regular{Text: "rclone cockpit", FontWeight: menuet.WeightBold},
		menuet.Separator{},
	}
	remotes, err := client.ListRemotes()
	if err != nil {
		return append(items, menuet.Regular{Text: "error: " + err.Error(), Color: menuet.SystemRed})
	}
	if len(remotes) == 0 {
		return append(items, menuet.Regular{Text: "no remotes configured"})
	}
	for _, r := range remotes {
		name := r.Name
		st := client.MountState(name)
		items = append(items, menuet.Regular{
			Runs: []menuet.TextRun{
				{Text: name + "  "},
				{Text: st.String(), Color: stateColor(st)},
			},
			Children: func() []menuet.MenuItem { return actions(name, st) },
		})
	}
	return items
}

// actions returns the submenu for a remote: the mount action for its current
// state, then a checkbox toggling auto-mount at login (the launchd plist).
func actions(name string, st core.MountStatus) []menuet.MenuItem {
	var items []menuet.MenuItem
	switch st {
	case core.Mounted:
		items = append(items,
			menuet.Regular{Text: "Unmount", Clicked: run(func() error { return client.Unmount(name) })})
	case core.Zombie:
		items = append(items,
			menuet.Regular{Text: "Repair (kill daemon + remount)",
				Clicked: run(func() error { return client.Repair(name) })},
			menuet.Regular{Text: "Unmount", Clicked: run(func() error { return client.Unmount(name) })})
	default:
		items = append(items,
			menuet.Regular{Text: "Mount", Clicked: run(func() error { return client.Mount(name) })})
	}

	// auto-mount at login — distinct from the app's own "Start at Login":
	// this generates/removes the launchd plist that brings the MOUNT up on boot.
	auto := client.HasAutostartMount(name)
	items = append(items,
		menuet.Separator{},
		menuet.Regular{
			Text:  "Mount at login",
			State: auto, // checkmark when enabled
			Clicked: run(func() error {
				if auto {
					return client.AutostartMountOff(name)
				}
				return client.AutostartMountOn(name)
			}),
		})
	return items
}

// stateColor maps a mount state to a semantic (dark/light-adaptive) color.
func stateColor(s core.MountStatus) menuet.Color {
	switch s {
	case core.Mounted:
		return menuet.SystemGreen
	case core.Zombie:
		return menuet.SystemOrange
	default:
		return menuet.LabelSecondary
	}
}

func main() {
	app := menuet.App()
	app.Name = "rclone cockpit"
	app.Label = "com.marlus.rclone-cockpit"
	app.Children = menu

	// keep state live even when nobody clicks (e.g. a mount goes zombie)
	go func() {
		for {
			refresh()
			time.Sleep(5 * time.Second)
		}
	}()

	app.RunApplication()
}
