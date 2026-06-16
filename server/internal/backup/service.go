// Package backup implements the v0.2.0 online SQLite backup and the
// destructive restore + runtime-state rotation flow.
//
// Spec section "Backup and restore":
//   - backup_to: SQLite online backup (VACUUM INTO) — server stays available.
//   - restore_from: stop accepting writes, swap the live db file, bump
//     server_runtime_state.generation, rotate jwt_kid + jwt_signing_key,
//     and broadcast server_restored to every connected WS session.
//
// All admin actions are gated behind the Unix socket control RPC; this
// package never opens or writes to a network endpoint.
package backup

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// JWTSigningKeyLen is the size of the freshly-rotated HMAC-SHA256 secret.
const JWTSigningKeyLen = 32

// DefaultBroadcastGrace is the spec-mandated pause between broadcasting
// the server_restored event and tearing down the WS sessions, so the
// event is delivered before clients are disconnected.
const DefaultBroadcastGrace = time.Second

// Service performs backup and restore against the live storage.DB and the
// in-memory ws.Hub. The Service does not hold any background state; the
// restore mutex is owned per-call.
type Service struct {
	mu             sync.Mutex
	broadcastGrace time.Duration
}

// New constructs a backup Service.
func New() *Service { return &Service{broadcastGrace: DefaultBroadcastGrace} }

// NewWithBroadcastGrace lets tests skip the spec-mandated 1-second pause
// between server_restored broadcast and session teardown.
func NewWithBroadcastGrace(grace time.Duration) *Service {
	return &Service{broadcastGrace: grace}
}

// BackupTo runs SQLite's VACUUM INTO against destPath. The destination must
// not already exist (matches sqlite3 semantics). The server stays available
// for reads and other writes throughout — VACUUM INTO holds a shared lock
// only briefly per page.
func (s *Service) BackupTo(ctx context.Context, db *storage.DB, destPath string) error {
	if destPath == "" {
		return errors.New("backup destination path required")
	}
	if err := validateAdminPath(destPath); err != nil {
		return err
	}
	abs, err := filepath.Abs(destPath)
	if err != nil {
		return fmt.Errorf("backup path: %w", err)
	}
	if _, err := os.Stat(abs); err == nil {
		return fmt.Errorf("backup destination already exists: %s", abs)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("stat backup destination: %w", err)
	}

	// Ensure parent dir exists.
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		return fmt.Errorf("create backup parent dir: %w", err)
	}

	// VACUUM INTO is the recommended online-backup primitive in modern
	// SQLite (3.27+). It is atomic from the perspective of the destination
	// file and uses a fresh database header so the restored file is
	// guaranteed not to inherit WAL state.
	if _, err := db.ExecContext(ctx, "VACUUM INTO ?", abs); err != nil {
		return fmt.Errorf("vacuum into %s: %w", abs, err)
	}
	return nil
}

// RestoreResult is the outcome of a successful RestoreFrom.
type RestoreResult struct {
	Generation     int64
	JWTKid         string
	BroadcastCount int
}

// Reopener swaps the live *storage.DB pointer. The daemon supplies a
// closure that closes the current handle and opens a fresh one against
// the same path; tests inject an in-memory equivalent.
type Reopener interface {
	Reopen(ctx context.Context) (*storage.DB, error)
}

// ReopenerFunc adapts a function to the Reopener interface.
type ReopenerFunc func(ctx context.Context) (*storage.DB, error)

// Reopen calls the underlying function.
func (f ReopenerFunc) Reopen(ctx context.Context) (*storage.DB, error) { return f(ctx) }

// RestoreFrom replaces the live database file at livePath with the contents
// of srcPath, bumps server_runtime_state.generation, rotates the JWT signing
// key+kid, broadcasts a server_restored event over hub, and (after a brief
// grace) tears down all live WS sessions.
//
// The caller is expected to hold the daemon's reopen lock; the service
// uses its own mu to serialize back-to-back restore_from calls.
func (s *Service) RestoreFrom(
	ctx context.Context,
	current *storage.DB,
	livePath, srcPath string,
	reopener Reopener,
	hub *ws.Hub,
) (*storage.DB, *RestoreResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if livePath == "" {
		return nil, nil, errors.New("live database path required")
	}
	if srcPath == "" {
		return nil, nil, errors.New("restore source path required")
	}
	if err := validateAdminPath(srcPath); err != nil {
		return nil, nil, err
	}
	if reopener == nil {
		return nil, nil, errors.New("reopener required")
	}

	srcAbs, err := filepath.Abs(srcPath)
	if err != nil {
		return nil, nil, fmt.Errorf("source path: %w", err)
	}
	if _, err := os.Stat(srcAbs); err != nil {
		return nil, nil, fmt.Errorf("restore source: %w", err)
	}

	// Sanity check: the file must look like an SQLite database. Reading
	// the first 16 bytes should reveal "SQLite format 3\000".
	if err := assertSQLiteFile(srcAbs); err != nil {
		return nil, nil, err
	}

	// Read the inbound generation so we can resolve the MAX(restored, current)+1
	// invariant from the spec.
	inboundGen, err := readGenerationFromFile(ctx, srcAbs)
	if err != nil {
		return nil, nil, fmt.Errorf("inspect restore source: %w", err)
	}

	// Capture the current generation before we close the connection.
	var currentGen int64
	if err := current.QueryRowContext(
		ctx,
		`SELECT generation FROM server_runtime_state WHERE singleton = 1`,
	).Scan(&currentGen); err != nil {
		return nil, nil, fmt.Errorf("read current generation: %w", err)
	}

	// Stage the restore into a sibling file FIRST. If the copy fails (disk
	// full, permission, IO error) we have not touched the live DB and the
	// daemon stays serving the original data — fail-closed.
	stagedPath := livePath + ".restore.staging"
	_ = os.Remove(stagedPath)
	if err := copyFile(srcAbs, stagedPath); err != nil {
		return nil, nil, fmt.Errorf("stage restore copy: %w", err)
	}
	defer func() {
		_ = os.Remove(stagedPath)
	}()

	// Now close the live handle and swap the staged file into place. From
	// this point a failure leaves the live DB on disk in an inconsistent
	// state and the daemon must restart; the staging step above keeps the
	// common failure modes (bad source, no disk space) outside that window.
	if err := current.Close(); err != nil {
		return nil, nil, fmt.Errorf("close current db: %w", err)
	}
	if err := os.Rename(stagedPath, livePath); err != nil {
		return nil, nil, fmt.Errorf("swap db file: %w", err)
	}
	// Stale WAL/SHM files from the prior process can poison the freshly-
	// restored database — explicitly remove them.
	_ = os.Remove(livePath + "-wal")
	_ = os.Remove(livePath + "-shm")

	// Reopen the live DB at the original path.
	freshDB, err := reopener.Reopen(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("reopen db: %w", err)
	}

	// Compute new generation = MAX(restored, current) + 1, then rotate
	// jwt_kid + jwt_signing_key.
	newGen := inboundGen
	if currentGen > newGen {
		newGen = currentGen
	}
	newGen++

	newKid := "kid-" + uuid.NewString()
	newKey := make([]byte, JWTSigningKeyLen)
	if _, err := rand.Read(newKey); err != nil {
		return nil, nil, fmt.Errorf("rotate signing key: %w", err)
	}

	if err := freshDB.WriteTxDurable(ctx, func(tx *storage.Tx) error {
		_, err := tx.Exec(
			`UPDATE server_runtime_state
			 SET generation = ?, jwt_kid = ?, jwt_signing_key = ?
			 WHERE singleton = 1`,
			newGen, newKid, newKey,
		)
		return err
	}); err != nil {
		return nil, nil, fmt.Errorf("rotate runtime state: %w", err)
	}

	result := &RestoreResult{
		Generation: newGen,
		JWTKid:     newKid,
	}

	// Broadcast server_restored, sleep one second so the event drains to
	// every client's send buffer (per spec: "1-second post-broadcast grace
	// so the event is delivered first"), then tear down every connected
	// session. The hub is allowed to be nil in tests without WS wiring.
	if hub != nil {
		ev := ws.ServerRestored(newGen, newKid, freshDB.Clock.NowMillis())
		result.BroadcastCount = hub.Broadcast(ev)
		select {
		case <-time.After(s.broadcastGrace):
		case <-ctx.Done():
		}
		hub.CloseAll()
	}

	return freshDB, result, nil
}

func assertSQLiteFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open restore source: %w", err)
	}
	defer f.Close()
	header := make([]byte, 16)
	if _, err := io.ReadFull(f, header); err != nil {
		return fmt.Errorf("read restore header: %w", err)
	}
	if string(header) != "SQLite format 3\x00" {
		return errors.New("restore source is not an SQLite database")
	}
	return nil
}

// validateAdminPath rejects backup/restore paths that look like path-
// traversal attempts. We require an absolute, lexically-clean path with
// no `..` segments. The Unix-socket caller is privileged so this is
// defence-in-depth rather than a primary security boundary, but it
// catches operator typos that would otherwise write outside the
// intended backup root.
//
// Threat model: this check is LEXICAL only. Symlinks are NOT followed,
// so an operator with write access to the backup root could plant a
// symlink at e.g. /var/backup/snap.db pointing at /etc/passwd and the
// check would still pass. Mitigation is operational: the backup root
// must be owned by the daemon user and not writable by anyone else.
func validateAdminPath(p string) error {
	if !filepath.IsAbs(p) {
		return errors.New("path must be absolute")
	}
	cleaned := filepath.Clean(p)
	if cleaned != p {
		return fmt.Errorf("path must be lexically clean (got %q, expected %q)", p, cleaned)
	}
	for _, seg := range strings.Split(cleaned, string(filepath.Separator)) {
		if seg == ".." {
			return errors.New("path must not contain `..` segments")
		}
	}
	return nil
}

func readGenerationFromFile(ctx context.Context, path string) (int64, error) {
	// Open read-only against the source file so we don't perturb its WAL.
	dsn := fmt.Sprintf("file:%s?mode=ro&_pragma=busy_timeout(5000)", path)
	conn, err := sql.Open("sqlite", dsn)
	if err != nil {
		return 0, err
	}
	defer conn.Close()
	var gen int64
	row := conn.QueryRowContext(
		ctx,
		`SELECT generation FROM server_runtime_state WHERE singleton = 1`,
	)
	if err := row.Scan(&gen); err != nil {
		return 0, err
	}
	return gen, nil
}

// copyFileTempSuffix is the per-write intermediate suffix used by copyFile
// so a partial write never leaves a half-baked file at `dst`. The deferred
// `os.Remove(tmp)` below catches the panic / unexpected-exit case the
// explicit Remove calls below cannot.
const copyFileTempSuffix = ".copying"

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + copyFileTempSuffix
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	// Defence in depth: if the function returns before the rename, the tmp
	// file is left behind. Best-effort remove (no-op if rename succeeded).
	defer func() {
		_ = os.Remove(tmp)
	}()
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, dst); err != nil {
		return err
	}
	return nil
}
