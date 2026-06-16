// Package storage owns all SQLite access for the nesttalk server.
//
// Single-writer model: callers serialize mutations through this package's
// transaction helpers. Mutating handlers run inside BEGIN IMMEDIATE
// TRANSACTION. The four security-critical write paths
// (enrollment_links insert, enrollment_links.challenge update,
// auth/enroll/complete, auth_nonces insert/consume) raise
// PRAGMA synchronous=FULL for the duration of the transaction.
// See spec section "Durability for security-critical writes".
package storage

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"sort"
	"strings"

	_ "modernc.org/sqlite"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// DB wraps the *sql.DB and the chosen Clock. Construct via Open.
type DB struct {
	*sql.DB
	Clock Clock
}

// Open opens (and creates if necessary) the SQLite file at path, applies
// all embedded migrations in alphanumeric order, and returns a ready-to-use
// DB pinned to the SystemClock. Tests should call OpenWithClock to inject
// a FixedClock instead.
func Open(path string) (*DB, error) {
	return OpenWithClock(path, SystemClock{})
}

// OpenWithClock is Open but with an injected Clock (used by tests).
func OpenWithClock(path string, clock Clock) (*DB, error) {
	dsn := fmt.Sprintf("file:%s?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)", path)
	sqlDB, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// Single-writer model — one open connection prevents the modernc driver
	// from rotating connections and dropping per-connection PRAGMAs.
	sqlDB.SetMaxOpenConns(1)

	db := &DB{DB: sqlDB, Clock: clock}
	if err := db.applyMigrations(); err != nil {
		_ = sqlDB.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return db, nil
}

// applyMigrations runs every embedded SQL file in lexical order if the
// schema_migrations table doesn't already record it.
func (d *DB) applyMigrations() error {
	if _, err := d.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
		version TEXT PRIMARY KEY,
		applied_at INTEGER NOT NULL
	)`); err != nil {
		return err
	}

	entries, err := migrationsFS.ReadDir("migrations")
	if err != nil {
		return err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	for _, name := range names {
		var seen int
		if err := d.QueryRow(
			"SELECT COUNT(*) FROM schema_migrations WHERE version = ?", name,
		).Scan(&seen); err != nil {
			return err
		}
		if seen > 0 {
			continue
		}
		body, err := migrationsFS.ReadFile("migrations/" + name)
		if err != nil {
			return err
		}
		// Apply the body AND record the version in ONE transaction. SQLite DDL
		// is transactional, so a crash mid-migration rolls back both — otherwise
		// a crash after the DDL but before the version insert would replay the
		// DDL on the next boot and fail (e.g. "duplicate column name"), bricking
		// startup.
		if err := d.WriteTxDurable(context.Background(), func(tx *Tx) error {
			if _, err := tx.Exec(string(body)); err != nil {
				return fmt.Errorf("apply %s: %w", name, err)
			}
			_, err := tx.Exec(
				"INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
				name, d.Clock.NowMillis(),
			)
			return err
		}); err != nil {
			return err
		}
	}
	return nil
}

// Tx is a single transaction handle. All Exec/Query calls run on the same
// pinned connection so the BEGIN IMMEDIATE lock and any per-connection
// PRAGMA (notably synchronous=FULL) stay in force for the entire body.
type Tx struct {
	conn *sql.Conn
	ctx  context.Context
}

// Exec runs a write statement.
func (t *Tx) Exec(q string, args ...any) (sql.Result, error) {
	return t.conn.ExecContext(t.ctx, q, args...)
}

// Query runs a query.
func (t *Tx) Query(q string, args ...any) (*sql.Rows, error) {
	return t.conn.QueryContext(t.ctx, q, args...)
}

// QueryRow runs a single-row query.
func (t *Tx) QueryRow(q string, args ...any) *sql.Row {
	return t.conn.QueryRowContext(t.ctx, q, args...)
}

// CurrentSynchronous reports the synchronous PRAGMA in force on this
// transaction's connection ("FULL", "NORMAL", ...). Used by tests.
func (t *Tx) CurrentSynchronous() (string, error) {
	var v string
	if err := t.conn.QueryRowContext(t.ctx, "PRAGMA synchronous").Scan(&v); err != nil {
		return "", err
	}
	return decodeSync(v), nil
}

func decodeSync(raw string) string {
	switch raw {
	case "0":
		return "OFF"
	case "1":
		return "NORMAL"
	case "2":
		return "FULL"
	case "3":
		return "EXTRA"
	}
	return raw
}

// WriteTx runs fn inside a BEGIN IMMEDIATE transaction with synchronous=NORMAL.
func (d *DB) WriteTx(ctx context.Context, fn func(*Tx) error) error {
	return d.writeTx(ctx, "NORMAL", fn)
}

// WriteTxDurable runs fn inside a BEGIN IMMEDIATE transaction with
// synchronous=FULL. Use for the four security-critical write paths.
func (d *DB) WriteTxDurable(ctx context.Context, fn func(*Tx) error) error {
	return d.writeTx(ctx, "FULL", fn)
}

func (d *DB) writeTx(ctx context.Context, sync string, fn func(*Tx) error) (retErr error) {
	conn, err := d.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()

	if _, err := conn.ExecContext(ctx, fmt.Sprintf("PRAGMA synchronous = %s", sync)); err != nil {
		return fmt.Errorf("set synchronous=%s: %w", sync, err)
	}

	if _, err := conn.ExecContext(ctx, "BEGIN IMMEDIATE TRANSACTION"); err != nil {
		return fmt.Errorf("begin immediate: %w", err)
	}

	tx := &Tx{conn: conn, ctx: ctx}

	// Panic safety: with MaxOpenConns=1 a leaked open transaction would
	// poison the next caller ("transaction within a transaction"). Roll
	// back best-effort on panic and re-raise so the bug is still visible.
	defer func() {
		if r := recover(); r != nil {
			_, _ = conn.ExecContext(ctx, "ROLLBACK")
			panic(r)
		}
	}()

	if err := fn(tx); err != nil {
		_, _ = conn.ExecContext(ctx, "ROLLBACK")
		return err
	}
	if _, err := conn.ExecContext(ctx, "COMMIT"); err != nil {
		_, _ = conn.ExecContext(ctx, "ROLLBACK")
		return err
	}
	// Reset PRAGMA synchronous to NORMAL after COMMIT so this connection
	// returns to the pool at the baseline fsync setting; PRAGMA
	// synchronous cannot be altered inside a transaction, so it must
	// happen here before defer conn.Close() releases the connection.
	if sync != "NORMAL" {
		if _, err := conn.ExecContext(ctx, "PRAGMA synchronous = NORMAL"); err != nil {
			return fmt.Errorf("reset synchronous=NORMAL: %w", err)
		}
	}
	return nil
}

// ErrNotFound is returned when a row lookup misses.
var ErrNotFound = errors.New("not found")

// Vacuum runs SQLite VACUUM on the database at path using a fresh, dedicated
// sql.DB connection opened in autocommit mode (no active transaction). This
// is required because SQLite forbids VACUUM inside any transaction.
//
// The caller is responsible for ensuring no other connection is in a write
// transaction while VACUUM runs (use the control socket serialisation lock).
// After VACUUM returns the caller should close the existing DB handle and
// reopen it so all deps see the rewritten file.
func Vacuum(ctx context.Context, path string) error {
	// Open a dedicated connection outside the singleton wrapper so we do
	// not interfere with the running pool, and so we have full control
	// over the connection lifecycle.
	dsn := fmt.Sprintf("file:%s?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)", path)
	conn, err := sql.Open("sqlite", dsn)
	if err != nil {
		return fmt.Errorf("vacuum: open: %w", err)
	}
	defer conn.Close()
	// VACUUM must run in autocommit mode — no surrounding transaction.
	if _, err := conn.ExecContext(ctx, "VACUUM"); err != nil {
		return fmt.Errorf("vacuum: %w", err)
	}
	return nil
}
