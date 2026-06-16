package backup_test

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/backup"
)

func TestBackupTo_RejectsBadPaths(t *testing.T) {
	dir := t.TempDir()
	livePath := filepath.Join(dir, "live.db")
	db := openTestDB(t, livePath)
	t.Cleanup(func() { _ = db.Close() })

	svc := backup.NewWithBroadcastGrace(0)
	ctx := context.Background()

	cases := map[string]string{
		"empty":   "",
		"relative": "relative/path.db",
		"unclean":  "/tmp/foo/../bar.db",
		"dotdot":   "/tmp/../etc/passwd",
	}
	for name, p := range cases {
		t.Run(name, func(t *testing.T) {
			assert.Error(t, svc.BackupTo(ctx, db, p))
		})
	}

	// Destination already exists → error.
	existing := filepath.Join(dir, "exists.db")
	require.NoError(t, svc.BackupTo(ctx, db, existing))
	assert.Error(t, svc.BackupTo(ctx, db, existing), "must refuse to overwrite an existing file")
}
