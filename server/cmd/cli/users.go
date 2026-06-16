package main

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"
)

func enrollCmd() *cobra.Command {
	var qrOut string
	cmd := &cobra.Command{
		Use:   "enroll <name>",
		Short: "Issue a new-user enrollment link",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var out struct {
				Code      string `json:"code"`
				ExpiresAt int64  `json:"expires_at"`
			}
			err := newClient().Call("enroll_user", map[string]string{"name": args[0]}, &out)
			if err != nil {
				return err
			}
			invite, err := buildInviteURL(out.Code)
			if err != nil {
				return err
			}
			fmt.Println(invite)
			if qrOut != "" {
				fmt.Fprintln(os.Stderr, "(--qr-out: QR PNG output is not implemented yet in Slice 1a)")
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&qrOut, "qr-out", "", "write QR PNG to this path (Slice 7b)")
	return cmd
}

func enrollExistingCmd() *cobra.Command {
	var userID string
	cmd := &cobra.Command{
		Use:   "enroll-existing",
		Short: "Issue a re-enrollment link for an existing user_id",
		RunE: func(cmd *cobra.Command, args []string) error {
			if userID == "" {
				return fmt.Errorf("--user is required")
			}
			var out struct {
				Code      string `json:"code"`
				ExpiresAt int64  `json:"expires_at"`
			}
			err := newClient().Call("enroll_existing_user", map[string]string{"user_id": userID}, &out)
			if err != nil {
				return err
			}
			invite, err := buildInviteURL(out.Code)
			if err != nil {
				return err
			}
			fmt.Println(invite)
			return nil
		},
	}
	cmd.Flags().StringVar(&userID, "user", "", "existing user_id to re-enroll")
	return cmd
}

func revokeCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "revoke <user_id>",
		Short: "Revoke a user (and their active device)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var out struct {
				RevokedAt int64 `json:"revoked_at"`
			}
			if err := newClient().Call("revoke_user", map[string]string{"user_id": args[0]}, &out); err != nil {
				return err
			}
			fmt.Printf("User %s revoked at %s\n", args[0], time.UnixMilli(out.RevokedAt).UTC().Format(time.RFC3339))
			return nil
		},
	}
}

func listUsersCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list-users",
		Short: "List every user (enrolled and revoked)",
		RunE: func(cmd *cobra.Command, args []string) error {
			var out struct {
				Users []struct {
					UserID      string `json:"user_id"`
					DisplayName string `json:"display_name"`
					ColorHint   int    `json:"color_hint"`
					EnrolledAt  int64  `json:"enrolled_at"`
					RevokedAt   *int64 `json:"revoked_at,omitempty"`
					LastSeenAt  *int64 `json:"last_seen_at,omitempty"`
				} `json:"users"`
			}
			if err := newClient().Call("list_users", map[string]any{}, &out); err != nil {
				return err
			}
			fmt.Printf("%-36s %-20s %-12s %s\n", "USER_ID", "DISPLAY_NAME", "STATE", "LAST_SEEN")
			for _, u := range out.Users {
				state := "active"
				if u.RevokedAt != nil {
					state = "revoked"
				}
				lastSeen := "-"
				if u.LastSeenAt != nil {
					lastSeen = time.UnixMilli(*u.LastSeenAt).UTC().Format(time.RFC3339)
				}
				fmt.Printf("%-36s %-20s %-12s %s\n", u.UserID, u.DisplayName, state, lastSeen)
			}
			return nil
		},
	}
}

func listEnrollmentLinksCmd() *cobra.Command {
	var includeUsed bool
	cmd := &cobra.Command{
		Use:   "list-enrollment-links",
		Short: "List outstanding (and optionally consumed) enrollment links",
		RunE: func(cmd *cobra.Command, args []string) error {
			var out struct {
				Links []struct {
					Code           string  `json:"code"`
					CreatedForName string  `json:"created_for_name"`
					TargetUserID   *string `json:"target_user_id,omitempty"`
					CreatedAt      int64   `json:"created_at"`
					ExpiresAt      int64   `json:"expires_at"`
					UsedByDeviceID *string `json:"used_by_device_id,omitempty"`
				} `json:"enrollment_links"`
			}
			if err := newClient().Call("list_enrollment_links", map[string]any{"include_used": includeUsed}, &out); err != nil {
				return err
			}
			fmt.Printf("%-44s %-16s %-22s %-22s %s\n", "CODE", "FOR", "EXPIRES_AT", "TARGET_USER_ID", "STATE")
			for _, l := range out.Links {
				state := "open"
				if l.UsedByDeviceID != nil {
					state = "consumed"
				}
				targetUser := "-"
				if l.TargetUserID != nil {
					targetUser = *l.TargetUserID
				}
				fmt.Printf("%-44s %-16s %-22s %-22s %s\n",
					l.Code, l.CreatedForName,
					time.UnixMilli(l.ExpiresAt).UTC().Format(time.RFC3339),
					targetUser, state)
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&includeUsed, "include-used", false, "also show consumed links")
	return cmd
}

// buildInviteURL produces the v0.2.2 opaque invite link. The payload is a
// zlib-compressed, base64url-encoded JSON blob carrying the enrollment
// code and the REALITY transport parameters. The link uses the custom
// `nesttalk://i/<blob>` scheme so the server IP/hostname is never
// visible on the wire or in pasted invites — everything the client needs
// lives inside the blob.
func buildInviteURL(code string) (string, error) {
	transport := map[string]any{
		"kind":        "reality",
		"server_addr": os.Getenv("REALITY_SERVER_ADDR"),
		"sni":         envOrDefault("REALITY_SNI", "cloudflare.com"),
		"public_key":  os.Getenv("REALITY_PUBLIC_KEY"),
		"short_id":    os.Getenv("REALITY_SHORT_ID"),
	}
	// VLESS inbound UUIDs. The client's `hasRealityBootstrap` check
	// requires at least `api_uuid` (or legacy `uuid`) to be present; a
	// missing value leaves the fresh-install client stuck on
	// "Bad state: Transport bootstrap did not create a session service."
	if v := os.Getenv("REALITY_API_UUID"); v != "" {
		transport["api_uuid"] = v
	}
	if v := os.Getenv("REALITY_TURN_UUID"); v != "" {
		transport["turn_uuid"] = v
	}
	payload := map[string]any{
		"v":         1,
		"code":      code,
		"transport": transport,
	}
	jsonBytes, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	var compressed bytes.Buffer
	zw := zlib.NewWriter(&compressed)
	if _, err := zw.Write(jsonBytes); err != nil {
		return "", err
	}
	if err := zw.Close(); err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(compressed.Bytes())
	return "nesttalk://i/" + encoded, nil
}
