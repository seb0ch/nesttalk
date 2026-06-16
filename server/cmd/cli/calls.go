package main

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/spf13/cobra"
)

// listRecentCallsCmd returns the cobra command for list-recent-calls.
// It calls the server's control RPC dispatcher which delegates to the
// calls.Manager.ListRecentCalls via the control package (registered in Slice 4).
//
// Args: --limit (default 50, max 500), --before (unix milliseconds for cursor).
func listRecentCallsCmd() *cobra.Command {
	var limit int
	var before int64

	cmd := &cobra.Command{
		Use:   "list-recent-calls",
		Short: "List recent calls (paginated, newest first)",
		RunE: func(cmd *cobra.Command, args []string) error {
			req := map[string]any{"limit": limit}
			if cmd.Flags().Changed("before") {
				req["before_started_at"] = before
			}

			var out struct {
				Calls []struct {
					ID           string  `json:"id"`
					CallerUserID string  `json:"caller_user_id"`
					CalleeUserID string  `json:"callee_user_id"`
					Kind         string  `json:"kind"`
					State        string  `json:"state"`
					EndedReason  *string `json:"ended_reason,omitempty"`
					StartedAt    int64   `json:"started_at"`
					ConnectedAt  *int64  `json:"connected_at,omitempty"`
					EndedAt      *int64  `json:"ended_at,omitempty"`
				} `json:"calls"`
			}
			if err := newClient().Call("list_recent_calls", req, &out); err != nil {
				return err
			}

			if len(out.Calls) == 0 {
				fmt.Println("(no calls)")
				return nil
			}

			fmt.Printf("%-36s %-10s %-11s %-36s %-36s %-26s %s\n",
				"CALL_ID", "KIND", "STATE", "CALLER", "CALLEE", "STARTED_AT", "ENDED_REASON")
			for _, c := range out.Calls {
				endedReason := "-"
				if c.EndedReason != nil {
					endedReason = *c.EndedReason
				}
				started := time.UnixMilli(c.StartedAt).UTC().Format(time.RFC3339)
				fmt.Printf("%-36s %-10s %-11s %-36s %-36s %-26s %s\n",
					c.ID, c.Kind, c.State, c.CallerUserID, c.CalleeUserID, started, endedReason)
			}

			// Print pagination hint.
			if len(out.Calls) == limit {
				last := out.Calls[len(out.Calls)-1]
				raw, _ := json.Marshal(last.StartedAt)
				fmt.Printf("\nNext page: --before %s\n", raw)
			}
			return nil
		},
	}

	cmd.Flags().IntVar(&limit, "limit", 50, "maximum rows to return (1-500)")
	cmd.Flags().Int64Var(&before, "before", 0, "return calls with started_at < this unix-millis value (pagination cursor)")
	return cmd
}
