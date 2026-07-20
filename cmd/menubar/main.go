// Command menubar is the macOS status-bar front-end for rclone-cockpit.
// This is the v1 walking skeleton: it renders live remote state from the shared
// core package. Actions (mount/unmount/sync) come next.
package main

import (
	"fmt"
	"time"

	"github.com/caseymrm/menuet/v2"
	"github.com/sulram/rclone-cockpit/core"
)

var client = core.New()

// title reflects the overall state in the menu bar: cloud icon plus a count,
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

// menu builds the dropdown: one row per remote, showing its state.
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
		st := client.MountState(r.Name)
		items = append(items, menuet.Regular{Runs: []menuet.TextRun{
			{Text: r.Name + "  "},
			{Text: st.String(), Color: stateColor(st)},
		}})
	}
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

	// refresh the bar + menu every few seconds so state stays live
	go func() {
		for {
			app.SetMenuState(title())
			app.MenuChanged()
			time.Sleep(5 * time.Second)
		}
	}()

	app.RunApplication()
}
