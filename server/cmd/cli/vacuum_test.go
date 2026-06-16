package main

import (
	"bytes"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// executeCmd is a test helper that builds a root cobra command containing the
// given subcommand, invokes it with args, and returns any printed output plus
// the resulting error. It does NOT dial the control socket.
func executeCmd(t *testing.T, sub *cobra.Command, args ...string) (string, error) {
	t.Helper()
	root := &cobra.Command{Use: "cli"}
	root.AddCommand(sub)

	buf := &bytes.Buffer{}
	root.SetOut(buf)
	root.SetErr(buf)
	root.SetArgs(args)

	err := root.Execute()
	return buf.String(), err
}

// TestVacuumCmd_HelpText verifies the vacuum subcommand is registered and
// exposes usage information without requiring a running control socket.
func TestVacuumCmd_HelpText(t *testing.T) {
	out, err := executeCmd(t, vacuumCmd(), "vacuum", "--help")
	// cobra returns nil even for --help; the important thing is the help
	// text is present.
	_ = err
	assert.Contains(t, out, "vacuum", "help output should describe the vacuum subcommand")
	assert.Contains(t, out, "VACUUM", "help output should mention VACUUM")
}

// TestEmergencyShellCmd_HelpText verifies the emergency-shell subcommand is
// registered and surfaces help text without attempting to spawn sqlite3.
func TestEmergencyShellCmd_HelpText(t *testing.T) {
	out, err := executeCmd(t, emergencyShellCmd(), "emergency-shell", "--help")
	_ = err
	assert.Contains(t, out, "emergency-shell", "help output should describe the subcommand")
	// The Short description contains DANGER and appears in the root-level
	// help listing; the Long description appears in the subcommand's own
	// --help output. Either confirms the warning is wired.
	cmd := emergencyShellCmd()
	assert.Contains(t, cmd.Short, "DANGER", "Short description must contain DANGER warning")
	// The Long description must also mention the risk so `emergency-shell --help` is self-explanatory.
	assert.Contains(t, out, "sqlite3", "help output should mention sqlite3")
	_ = out
}

// TestVacuumCmd_Use verifies the cobra Use field is exactly "vacuum" so
// the ntctl wrapper can forward it without quoting.
func TestVacuumCmd_Use(t *testing.T) {
	cmd := vacuumCmd()
	require.Equal(t, "vacuum", cmd.Use)
}

// TestEmergencyShellCmd_Use verifies the cobra Use field is exactly
// "emergency-shell".
func TestEmergencyShellCmd_Use(t *testing.T) {
	cmd := emergencyShellCmd()
	require.Equal(t, "emergency-shell", cmd.Use)
}
