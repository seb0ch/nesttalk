// cli is the admin tool for nesttalk-server. It talks to the daemon over
// the Unix domain socket exposed by the control package; it never opens
// the SQLite database file directly (the documented exception, the
// `emergency-shell` subcommand, is intentionally NOT yet implemented in
// Slice 1a).
package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var socketPath string

func main() {
	root := &cobra.Command{
		Use:   "cli",
		Short: "NestTalk server administration CLI",
		Long: `cli sends newline-delimited JSON RPCs to nesttalk-server over the
admin Unix domain socket (default /var/run/nesttalk/control.sock).`,
	}

	root.PersistentFlags().StringVar(&socketPath, "socket",
		envOrDefault("NESTTALK_CONTROL_SOCKET", "/var/run/nesttalk/control.sock"),
		"path to the admin Unix domain socket")

	// Canonical subcommands ship at the root per spec.
	root.AddCommand(
		enrollCmd(),
		enrollExistingCmd(),
		revokeCmd(),
		revokeDeviceCmd(),
		listUsersCmd(),
		listEnrollmentLinksCmd(),
		reconcileDeviceCmd(),
		reloadConfigCmd(),
		backupToCmd(),
		restoreFromCmd(),
		// Slice 4: call management
		listRecentCallsCmd(),
		// Slice 7b: operator hardening
		vacuumCmd(),
		emergencyShellCmd(),
	)

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
