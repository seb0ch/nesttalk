package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/spf13/cobra"
)

// vacuumCmd submits a control RPC that causes the server to:
//  1. Close its current DB connection.
//  2. Run SQLite VACUUM on a fresh dedicated connection in autocommit mode
//     (SQLite forbids VACUUM inside any transaction).
//  3. Reopen the daemon's DB pointer via the same reopener used by
//     restore-from, so all dependencies see the freshly-rewritten file.
//
// IMPORTANT: run `backup-to` before `vacuum` — VACUUM rewrites the entire
// database file and is not transactional. A crash mid-vacuum leaves the
// file in an undefined state.
func vacuumCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "vacuum",
		Short: "Run SQLite VACUUM against the live database (online, blocking)",
		Long: `Submits a vacuum RPC to the server's control socket.

The server:
  1. Closes its current database connection.
  2. Runs VACUUM on a fresh, dedicated connection in autocommit mode
     (SQLite restriction: VACUUM cannot run inside any transaction).
  3. Reopens the daemon's database pointer so all services see the
     freshly-rewritten file.

IMPORTANT: Always run 'backup-to' BEFORE 'vacuum'. VACUUM rewrites the
entire database file; a crash mid-vacuum may leave the file in an
undefined state. Backups are your recovery path.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			var out struct {
				VacuumedAt int64 `json:"vacuumed_at"`
			}
			if err := newClient().Call("vacuum", map[string]any{}, &out); err != nil {
				return err
			}
			fmt.Printf("VACUUM complete at %s\n", time.UnixMilli(out.VacuumedAt).UTC().Format(time.RFC3339))
			return nil
		},
	}
}

// emergencyShellCmd opens an interactive sqlite3 shell directly against the
// live database file, bypassing the control socket entirely.
//
// This subcommand is a LAST-RESORT RECOVERY TOOL for situations where the
// daemon is completely unreachable (e.g. the control socket is gone, the
// server process is crashed and won't restart). It must NOT be used while
// the daemon is running — concurrent writes will corrupt the database.
//
// The command reads the DB path from the same environment variable the
// server uses (DB_PATH, default /var/lib/nesttalk/nesttalk.db) and execs
// into the system sqlite3 binary without contacting the control socket.
func emergencyShellCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "emergency-shell",
		Short: "DANGER: open an sqlite3 shell directly against the live database (daemon must NOT be running)",
		Long: `Opens an interactive sqlite3 shell directly against the live database file.

This BYPASSES the control socket entirely and should only be used as a
last-resort recovery tool when the daemon is completely unreachable.

If the daemon IS running while this command is used, you WILL risk data
corruption.

After entering the shell, remember to close it (.quit) before
restarting the daemon.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			dbPath := envOrDefault("DB_PATH", "/var/lib/nesttalk/nesttalk.db")

			fmt.Fprintln(os.Stderr, "")
			fmt.Fprintln(os.Stderr, "╔══════════════════════════════════════════════════════════════╗")
			fmt.Fprintln(os.Stderr, "║  DANGER: emergency sqlite3 shell                             ║")
			fmt.Fprintln(os.Stderr, "╠══════════════════════════════════════════════════════════════╣")
			fmt.Fprintln(os.Stderr, "║                                                              ║")
			fmt.Fprintln(os.Stderr, "║  Opening sqlite3 shell against the LIVE database:            ║")
			fmt.Fprintf(os.Stderr,  "║    %s%-55s║\n", dbPath, "")
			fmt.Fprintln(os.Stderr, "║                                                              ║")
			fmt.Fprintln(os.Stderr, "║  The daemon MUST NOT be running. If it is, you risk          ║")
			fmt.Fprintln(os.Stderr, "║  data corruption.                                            ║")
			fmt.Fprintln(os.Stderr, "║                                                              ║")
			fmt.Fprintln(os.Stderr, "║  Use ONLY as a last-resort recovery tool.                    ║")
			fmt.Fprintln(os.Stderr, "║                                                              ║")
			fmt.Fprintln(os.Stderr, "╚══════════════════════════════════════════════════════════════╝")
			fmt.Fprintln(os.Stderr, "")
			fmt.Fprint(os.Stderr, "Press Ctrl-C to abort, or Enter to continue... ")

			scanner := bufio.NewScanner(os.Stdin)
			if !scanner.Scan() {
				// EOF or Ctrl-C signal — abort
				fmt.Fprintln(os.Stderr, "\nAborted.")
				os.Exit(1)
			}

			sqlite3Path, err := exec.LookPath("sqlite3")
			if err != nil {
				return fmt.Errorf("sqlite3 not found in PATH: %w", err)
			}

			// exec into sqlite3 — this replaces the current process.
			// We use syscall.Exec-style replacement via exec.Command + os.Exit
			// to keep the binary small and avoid importing syscall directly.
			proc := exec.Command(sqlite3Path, dbPath)
			proc.Stdin = os.Stdin
			proc.Stdout = os.Stdout
			proc.Stderr = os.Stderr
			if err := proc.Run(); err != nil {
				// sqlite3 exited with non-zero — surface the exit code.
				if exitErr, ok := err.(*exec.ExitError); ok {
					os.Exit(exitErr.ExitCode())
				}
				return err
			}
			return nil
		},
	}
}
