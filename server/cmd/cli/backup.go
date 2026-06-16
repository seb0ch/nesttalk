package main

import (
	"fmt"

	"github.com/spf13/cobra"
)

func backupToCmd() *cobra.Command {
	var dest string
	cmd := &cobra.Command{
		Use:   "backup-to",
		Short: "Take an online SQLite snapshot to the given path",
		Long: `Runs the server's online backup (VACUUM INTO) and writes the result
to --to. The server stays available throughout. Caller-provided --to must
not already exist.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			if dest == "" {
				return fmt.Errorf("--to is required")
			}
			var out struct {
				Path string `json:"path"`
			}
			if err := newClient().Call("backup_to", map[string]string{"path": dest}, &out); err != nil {
				return err
			}
			fmt.Printf("Backup written to %s\n", out.Path)
			return nil
		},
	}
	cmd.Flags().StringVar(&dest, "to", "", "destination path for the snapshot (must not exist)")
	return cmd
}

func restoreFromCmd() *cobra.Command {
	var src string
	cmd := &cobra.Command{
		Use:   "restore-from",
		Short: "DESTRUCTIVE: replace the live database with a backup",
		Long: `Replaces the server's live database with the file at --from, bumps
server_runtime_state.generation, rotates the JWT signing key + kid, broadcasts
server_restored to every connected WebSocket session, and forces every active
session to re-handshake. All prior session tokens become invalid.

This is destructive — any data written to the live DB after the chosen
snapshot is lost. See ADMIN_GUIDE.md for the runbook.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			if src == "" {
				return fmt.Errorf("--from is required")
			}
			var out struct {
				Generation     int64  `json:"generation"`
				JWTKid         string `json:"jwt_kid"`
				BroadcastCount int    `json:"broadcast_count"`
			}
			if err := newClient().Call("restore_from", map[string]string{"path": src}, &out); err != nil {
				return err
			}
			fmt.Printf("Restore complete.\n")
			fmt.Printf("  generation       = %d\n", out.Generation)
			fmt.Printf("  jwt_kid          = %s\n", out.JWTKid)
			fmt.Printf("  sessions notified = %d (all forced to re-handshake)\n", out.BroadcastCount)
			return nil
		},
	}
	cmd.Flags().StringVar(&src, "from", "", "source backup file to restore from")
	return cmd
}
