package main

import (
	"fmt"
	"time"

	"github.com/spf13/cobra"
)

func revokeDeviceCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "revoke-device <device_id>",
		Short: "Revoke a single device without revoking the user",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var out struct {
				RevokedAt int64 `json:"revoked_at"`
			}
			if err := newClient().Call("revoke_device", map[string]string{"device_id": args[0]}, &out); err != nil {
				return err
			}
			fmt.Printf("Device %s revoked at %s\n", args[0], time.UnixMilli(out.RevokedAt).UTC().Format(time.RFC3339))
			return nil
		},
	}
}

func reconcileDeviceCmd() *cobra.Command {
	var pubkeyHex string
	cmd := &cobra.Command{
		Use:   "reconcile-device",
		Short: "Look up a device by Ed25519 fingerprint (emergency reconciliation)",
		RunE: func(cmd *cobra.Command, args []string) error {
			if pubkeyHex == "" {
				return fmt.Errorf("--pubkey is required (hex-encoded)")
			}
			var out struct {
				DeviceID  string `json:"device_id"`
				UserID    string `json:"user_id"`
				RevokedAt *int64 `json:"revoked_at,omitempty"`
			}
			if err := newClient().Call("reconcile_device", map[string]string{"pubkey_hex": pubkeyHex}, &out); err != nil {
				return err
			}
			state := "active"
			if out.RevokedAt != nil {
				state = fmt.Sprintf("revoked at %s", time.UnixMilli(*out.RevokedAt).UTC().Format(time.RFC3339))
			}
			fmt.Printf("Device:  %s\nUser:    %s\nStatus:  %s\n", out.DeviceID, out.UserID, state)
			return nil
		},
	}
	cmd.Flags().StringVar(&pubkeyHex, "pubkey", "", "hex-encoded Ed25519 public key (the device fingerprint)")
	return cmd
}
