package main

import (
	"fmt"
	"time"

	"github.com/spf13/cobra"
)

func reloadConfigCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "reload-config",
		Short: "Tell the server to reload its on-disk configuration",
		RunE: func(cmd *cobra.Command, args []string) error {
			var out struct {
				ReloadedAt int64 `json:"reloaded_at"`
			}
			if err := newClient().Call("reload_config", map[string]any{}, &out); err != nil {
				return err
			}
			fmt.Printf("Server reload acknowledged at %s\n", time.UnixMilli(out.ReloadedAt).UTC().Format(time.RFC3339))
			return nil
		},
	}
}
