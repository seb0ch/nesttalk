// Package control implements the Unix domain socket admin RPC: newline-
// delimited JSON, one request per line, per spec section "Control socket
// RPC". Every request carries a cmd_id (UUID) for idempotency; successful
// responses for already-seen cmd_ids are replayed from a TTL + bounded-
// size cache (1-hour TTL, 8192-entry hard cap, oldest-expiry first
// eviction). Failures are NOT cached so a transient error doesn't poison
// the same cmd_id for an hour.
package control

import (
	"bufio"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/seb0ch/nesttalk/server/internal/auth"
	"github.com/seb0ch/nesttalk/server/internal/storage"
)

// CmdReplayTTL is the 1-hour spec TTL for the replay-cache.
const CmdReplayTTL = time.Hour

// Request is the wire shape for an inbound RPC.
type Request struct {
	ID    int             `json:"id"`
	CmdID string          `json:"cmd_id"`
	Cmd   string          `json:"cmd"`
	Args  json.RawMessage `json:"args"`
}

// Response is the wire shape for an outbound RPC reply.
type Response struct {
	ID     int             `json:"id"`
	CmdID  string          `json:"cmd_id"`
	OK     bool            `json:"ok"`
	Error  string          `json:"error,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
}

// BackupRunner is the abstract surface the backup_to/restore_from/vacuum
// handlers need from the backup package. The concrete implementation
// lives in cmd/nesttalk-server which owns the live DB path + hub +
// reopener; tests inject a fake.
type BackupRunner interface {
	BackupTo(ctx context.Context, destPath string) error
	RestoreFrom(ctx context.Context, srcPath string) (generation int64, jwtKid string, broadcastCount int, err error)
	// Vacuum closes the daemon's current DB connection, runs SQLite VACUUM
	// on a fresh dedicated connection in autocommit mode (SQLite restriction:
	// VACUUM cannot run inside any transaction), then reopens the daemon's DB
	// pointer via the same reopener used by RestoreFrom. This mirrors the
	// Slice 1c restore_from pattern.
	Vacuum(ctx context.Context) error
}

// CallsLister is the abstract interface the list_recent_calls handler needs.
// Implemented by calls.Manager; kept as an interface here so the control
// package does not import the calls package and avoids a circular dependency.
type CallsLister interface {
	ListRecentCallsRaw(ctx context.Context, limit int, beforeStartedAt *int64) ([]map[string]any, error)
}

// Server is the control-socket RPC server.
type Server struct {
	DB       *storage.DB
	Auth     *auth.Service
	Reload   func() error  // hook called on reload_config
	Backup   BackupRunner  // wired in by the daemon for backup_to / restore_from
	Calls    CallsLister   // wired in by the daemon for list_recent_calls
	Sessions SessionCloser // wired in by the daemon to drop revoked live WS sessions
	listener net.Listener
	cache    *replayCache
	mu       sync.Mutex
}

// SessionCloser drops live WebSocket sessions on revocation. Implemented
// by *ws.Hub; an interface here keeps control decoupled from the hub.
type SessionCloser interface {
	DisconnectUser(userID string) int
	DisconnectDevice(deviceID string) int
}

// New constructs a Server.
func New(db *storage.DB, authSvc *auth.Service) *Server {
	return &Server{
		DB:    db,
		Auth:  authSvc,
		cache: newReplayCache(CmdReplayTTL),
	}
}

// Listen begins accepting connections on the unix socket at path. The
// listener is owned by the Server until Close.
func (s *Server) Listen(path string) error {
	l, err := net.Listen("unix", path)
	if err != nil {
		return fmt.Errorf("listen %s: %w", path, err)
	}
	s.listener = l
	return nil
}

// ServeAccept loops accept() and spawns one goroutine per connection.
// Returns when the listener is closed.
func (s *Server) ServeAccept(ctx context.Context) error {
	if s.listener == nil {
		return errors.New("control: not listening")
	}
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return nil
			default:
			}
			return err
		}
		go s.handleConn(ctx, conn)
	}
}

// Close shuts down the listener.
func (s *Server) Close() error {
	if s.listener == nil {
		return nil
	}
	return s.listener.Close()
}

func (s *Server) handleConn(ctx context.Context, conn net.Conn) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	w := bufio.NewWriter(conn)
	for scanner.Scan() {
		line := scanner.Bytes()
		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			writeJSON(w, Response{OK: false, Error: "bad json: " + err.Error()})
			continue
		}
		resp := s.dispatch(ctx, req)
		writeJSON(w, resp)
	}
}

func writeJSON(w *bufio.Writer, resp Response) {
	body, err := json.Marshal(resp)
	if err != nil {
		body = []byte(`{"ok":false,"error":"marshal failure"}`)
	}
	w.Write(body)
	w.WriteByte('\n')
	w.Flush()
}

// Dispatch is the public dispatch entry point (used directly by tests).
func (s *Server) Dispatch(ctx context.Context, req Request) Response {
	return s.dispatch(ctx, req)
}

// CacheSize reports the current number of cached cmd_id responses.
// Test-only accessor; do not call from production code paths.
func (s *Server) CacheSize() int {
	return s.cache.size()
}

func (s *Server) dispatch(ctx context.Context, req Request) Response {
	if req.CmdID == "" {
		return Response{ID: req.ID, OK: false, Error: "cmd_id required"}
	}
	if cached, ok := s.cache.get(req.CmdID); ok {
		// Stamp the inbound id for client correlation but reuse cached body.
		cached.ID = req.ID
		return cached
	}

	var resp Response
	resp.ID = req.ID
	resp.CmdID = req.CmdID

	switch req.Cmd {
	case "enroll_user":
		resp = s.enrollUser(ctx, req)
	case "enroll_existing_user":
		resp = s.enrollExistingUser(ctx, req)
	case "revoke_user":
		resp = s.revokeUser(ctx, req)
	case "revoke_device":
		resp = s.revokeDevice(ctx, req)
	case "reconcile_device":
		resp = s.reconcileDevice(ctx, req)
	case "list_users":
		resp = s.listUsers(ctx, req)
	case "list_enrollment_links":
		resp = s.listEnrollmentLinks(ctx, req)
	case "reload_config":
		resp = s.reloadConfig(ctx, req)
	case "backup_to":
		resp = s.backupTo(ctx, req)
	case "restore_from":
		resp = s.restoreFrom(ctx, req)
	case "list_recent_calls":
		resp = s.listRecentCalls(ctx, req)
	case "vacuum":
		resp = s.vacuum(ctx, req)
	default:
		resp.OK = false
		resp.Error = "unknown cmd: " + req.Cmd
	}
	resp.ID = req.ID
	resp.CmdID = req.CmdID
	// Cache only successful responses. Failures (e.g. transient DB
	// errors, "user not found", etc.) must not poison the same cmd_id
	// for the entire TTL — let the caller retry against fresh state.
	if resp.OK {
		s.cache.put(req.CmdID, resp)
	}
	return resp
}

// ----- handlers -----

type enrollUserArgs struct {
	Name string `json:"name"`
}
type enrollUserResult struct {
	Code      string `json:"code"`
	ExpiresAt int64  `json:"expires_at"`
}

func (s *Server) enrollUser(ctx context.Context, req Request) Response {
	var args enrollUserArgs
	if err := json.Unmarshal(req.Args, &args); err != nil || args.Name == "" {
		return Response{OK: false, Error: "name required"}
	}
	now := s.DB.Clock.NowMillis()
	code := newCode()
	expiresAt := now + auth.EnrollLinkTTL.Milliseconds()
	err := s.DB.WriteTxDurable(ctx, func(tx *storage.Tx) error {
		_, err := tx.Exec(
			`INSERT INTO enrollment_links (code, created_for_name, target_user_id, created_at, expires_at)
			 VALUES (?, ?, NULL, ?, ?)`,
			code, args.Name, now, expiresAt,
		)
		return err
	})
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	return okResult(enrollUserResult{Code: code, ExpiresAt: expiresAt})
}

type enrollExistingArgs struct {
	UserID string `json:"user_id"`
}

func (s *Server) enrollExistingUser(ctx context.Context, req Request) Response {
	var args enrollExistingArgs
	if err := json.Unmarshal(req.Args, &args); err != nil || args.UserID == "" {
		return Response{OK: false, Error: "user_id required"}
	}
	now := s.DB.Clock.NowMillis()
	expiresAt := now + auth.EnrollLinkTTL.Milliseconds()
	code := newCode()
	var displayName string
	err := s.DB.WriteTxDurable(ctx, func(tx *storage.Tx) error {
		var revokedAt sql.NullInt64
		err := tx.QueryRow(
			`SELECT display_name, revoked_at FROM users WHERE id = ?`,
			args.UserID,
		).Scan(&displayName, &revokedAt)
		if errors.Is(err, sql.ErrNoRows) {
			return errors.New("user not found")
		}
		if err != nil {
			return err
		}
		if revokedAt.Valid {
			return errors.New("user is revoked; create a new identity with enroll_user")
		}
		_, err = tx.Exec(
			`INSERT INTO enrollment_links (code, created_for_name, target_user_id, created_at, expires_at)
			 VALUES (?, ?, ?, ?, ?)`,
			code, displayName, args.UserID, now, expiresAt,
		)
		return err
	})
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	return okResult(enrollUserResult{Code: code, ExpiresAt: expiresAt})
}

type revokeUserArgs struct {
	UserID string `json:"user_id"`
}

func (s *Server) revokeUser(ctx context.Context, req Request) Response {
	var args revokeUserArgs
	if err := json.Unmarshal(req.Args, &args); err != nil || args.UserID == "" {
		return Response{OK: false, Error: "user_id required"}
	}
	now := s.DB.Clock.NowMillis()
	err := s.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		res, err := tx.Exec(`UPDATE users SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, now, args.UserID)
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return errors.New("user not found or already revoked")
		}
		_, err = tx.Exec(`UPDATE devices SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL`, now, args.UserID)
		return err
	})
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	// Drop the user's live WS session — ValidateSession blocks NEW
	// requests post-revoke, but an already-connected socket trusts its
	// upgrade-time claims indefinitely without this.
	if s.Sessions != nil {
		s.Sessions.DisconnectUser(args.UserID)
	}
	return okResult(map[string]any{"revoked_at": now})
}

type revokeDeviceArgs struct {
	DeviceID string `json:"device_id"`
}

func (s *Server) revokeDevice(ctx context.Context, req Request) Response {
	var args revokeDeviceArgs
	if err := json.Unmarshal(req.Args, &args); err != nil || args.DeviceID == "" {
		return Response{OK: false, Error: "device_id required"}
	}
	now := s.DB.Clock.NowMillis()
	err := s.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		res, err := tx.Exec(`UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, now, args.DeviceID)
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			return errors.New("device not found or already revoked")
		}
		return nil
	})
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	if s.Sessions != nil {
		s.Sessions.DisconnectDevice(args.DeviceID)
	}
	return okResult(map[string]any{"revoked_at": now})
}

type reconcileDeviceArgs struct {
	PubkeyHex string `json:"pubkey_hex"`
}

func (s *Server) reconcileDevice(ctx context.Context, req Request) Response {
	var args reconcileDeviceArgs
	if err := json.Unmarshal(req.Args, &args); err != nil || args.PubkeyHex == "" {
		return Response{OK: false, Error: "pubkey_hex required"}
	}
	pub, err := hex.DecodeString(args.PubkeyHex)
	if err != nil {
		return Response{OK: false, Error: "pubkey_hex must be hex"}
	}
	var (
		deviceID, userID string
		revokedAt        sql.NullInt64
	)
	err = s.DB.QueryRowContext(ctx,
		`SELECT id, user_id, revoked_at FROM devices WHERE public_key = ?`,
		pub,
	).Scan(&deviceID, &userID, &revokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Response{OK: false, Error: "no device with that pubkey"}
	}
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	out := map[string]any{
		"device_id": deviceID,
		"user_id":   userID,
	}
	if revokedAt.Valid {
		out["revoked_at"] = revokedAt.Int64
	}
	return okResult(out)
}

type userRow struct {
	UserID      string `json:"user_id"`
	DisplayName string `json:"display_name"`
	ColorHint   int    `json:"color_hint"`
	EnrolledAt  int64  `json:"enrolled_at"`
	RevokedAt   *int64 `json:"revoked_at,omitempty"`
	LastSeenAt  *int64 `json:"last_seen_at,omitempty"`
}

func (s *Server) listUsers(ctx context.Context, req Request) Response {
	rows, err := s.DB.QueryContext(ctx,
		`SELECT id, display_name, color_hint, enrolled_at, revoked_at, last_seen_at
		 FROM users ORDER BY enrolled_at`)
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	defer rows.Close()
	out := []userRow{}
	for rows.Next() {
		var (
			u  userRow
			rv sql.NullInt64
			ls sql.NullInt64
		)
		if err := rows.Scan(&u.UserID, &u.DisplayName, &u.ColorHint, &u.EnrolledAt, &rv, &ls); err != nil {
			return Response{OK: false, Error: err.Error()}
		}
		if rv.Valid {
			v := rv.Int64
			u.RevokedAt = &v
		}
		if ls.Valid {
			v := ls.Int64
			u.LastSeenAt = &v
		}
		out = append(out, u)
	}
	return okResult(map[string]any{"users": out})
}

type listLinksArgs struct {
	IncludeUsed bool `json:"include_used"`
}
type linkRow struct {
	Code           string  `json:"code"`
	CreatedForName string  `json:"created_for_name"`
	TargetUserID   *string `json:"target_user_id,omitempty"`
	CreatedAt      int64   `json:"created_at"`
	ExpiresAt      int64   `json:"expires_at"`
	UsedByDeviceID *string `json:"used_by_device_id,omitempty"`
}

func (s *Server) listEnrollmentLinks(ctx context.Context, req Request) Response {
	var args listLinksArgs
	_ = json.Unmarshal(req.Args, &args)
	q := `SELECT code, created_for_name, target_user_id, created_at, expires_at, used_by_device_id
	      FROM enrollment_links`
	if !args.IncludeUsed {
		q += " WHERE used_by_device_id IS NULL"
	}
	q += " ORDER BY created_at DESC"
	rows, err := s.DB.QueryContext(ctx, q)
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	defer rows.Close()
	out := []linkRow{}
	for rows.Next() {
		var (
			r              linkRow
			targetUserID   sql.NullString
			usedByDeviceID sql.NullString
		)
		if err := rows.Scan(&r.Code, &r.CreatedForName, &targetUserID, &r.CreatedAt, &r.ExpiresAt, &usedByDeviceID); err != nil {
			return Response{OK: false, Error: err.Error()}
		}
		if targetUserID.Valid {
			v := targetUserID.String
			r.TargetUserID = &v
		}
		if usedByDeviceID.Valid {
			v := usedByDeviceID.String
			r.UsedByDeviceID = &v
		}
		out = append(out, r)
	}
	return okResult(map[string]any{"enrollment_links": out})
}

func (s *Server) reloadConfig(ctx context.Context, req Request) Response {
	if s.Reload != nil {
		if err := s.Reload(); err != nil {
			return Response{OK: false, Error: err.Error()}
		}
	}
	return okResult(map[string]any{"reloaded_at": s.DB.Clock.NowMillis()})
}

type backupArgs struct {
	Path string `json:"path"`
}

type backupResult struct {
	Path string `json:"path"`
}

func (s *Server) backupTo(ctx context.Context, req Request) Response {
	var args backupArgs
	if err := json.Unmarshal(req.Args, &args); err != nil || args.Path == "" {
		return Response{OK: false, Error: "path required"}
	}
	if s.Backup == nil {
		return Response{OK: false, Error: "backup runner not configured"}
	}
	if err := s.Backup.BackupTo(ctx, args.Path); err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	return okResult(backupResult{Path: args.Path})
}

type restoreResult struct {
	Generation     int64  `json:"generation"`
	JWTKid         string `json:"jwt_kid"`
	BroadcastCount int    `json:"broadcast_count"`
}

func (s *Server) restoreFrom(ctx context.Context, req Request) Response {
	var args backupArgs
	if err := json.Unmarshal(req.Args, &args); err != nil || args.Path == "" {
		return Response{OK: false, Error: "path required"}
	}
	if s.Backup == nil {
		return Response{OK: false, Error: "backup runner not configured"}
	}
	gen, kid, broadcast, err := s.Backup.RestoreFrom(ctx, args.Path)
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	return okResult(restoreResult{
		Generation:     gen,
		JWTKid:         kid,
		BroadcastCount: broadcast,
	})
}

type listRecentCallsArgs struct {
	Limit           int    `json:"limit"`
	BeforeStartedAt *int64 `json:"before_started_at"`
}

func (s *Server) listRecentCalls(ctx context.Context, req Request) Response {
	if s.Calls == nil {
		return Response{OK: false, Error: "calls manager not configured"}
	}
	var args listRecentCallsArgs
	_ = json.Unmarshal(req.Args, &args)
	if args.Limit <= 0 {
		args.Limit = 50
	}
	rows, err := s.Calls.ListRecentCallsRaw(ctx, args.Limit, args.BeforeStartedAt)
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	return okResult(map[string]any{"calls": rows})
}

func (s *Server) vacuum(ctx context.Context, req Request) Response {
	if s.Backup == nil {
		return Response{OK: false, Error: "backup runner not configured"}
	}
	if err := s.Backup.Vacuum(ctx); err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	return okResult(map[string]any{"vacuumed_at": s.DB.Clock.NowMillis()})
}

func okResult(v any) Response {
	body, err := json.Marshal(v)
	if err != nil {
		return Response{OK: false, Error: err.Error()}
	}
	return Response{OK: true, Result: body}
}

func newCode() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return uuid.NewString()
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// ----- replay cache -----
//
// TTL + bounded size; oldest-expiry first eviction. Entries live for at
// most CmdReplayTTL; once the map reaches replayCacheMaxEntries any
// further put() evicts the entry with the smallest expireAt before
// inserting the new one. No background goroutine — eviction is amortised
// onto put() so there is no lifecycle to manage.

const replayCacheMaxEntries = 8192

type cacheEntry struct {
	resp     Response
	expireAt time.Time
}

type replayCache struct {
	mu  sync.Mutex
	ttl time.Duration
	m   map[string]cacheEntry
}

func newReplayCache(ttl time.Duration) *replayCache {
	return &replayCache{ttl: ttl, m: make(map[string]cacheEntry)}
}

func (c *replayCache) get(cmdID string) (Response, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[cmdID]
	if !ok {
		return Response{}, false
	}
	if time.Now().After(e.expireAt) {
		delete(c.m, cmdID)
		return Response{}, false
	}
	return e.resp, true
}

// put records resp under cmdID. Only successful responses should be
// cached; the dispatcher gates on resp.OK. Enforces a hard size cap by
// evicting the entry with the oldest expiration (which, with a uniform
// TTL, is also the oldest insertion).
func (c *replayCache) put(cmdID string, resp Response) {
	c.mu.Lock()
	defer c.mu.Unlock()
	// Opportunistic GC of expired entries before considering eviction.
	now := time.Now()
	if len(c.m) >= replayCacheMaxEntries {
		for k, v := range c.m {
			if now.After(v.expireAt) {
				delete(c.m, k)
			}
		}
	}
	// If still at the cap (no expired entries to reap), evict the entry
	// closest to expiry to make room. Iteration order is randomised by
	// Go but we scan the whole map, so the choice is deterministic.
	if len(c.m) >= replayCacheMaxEntries {
		var oldestKey string
		var oldestAt time.Time
		first := true
		for k, v := range c.m {
			if first || v.expireAt.Before(oldestAt) {
				oldestKey = k
				oldestAt = v.expireAt
				first = false
			}
		}
		delete(c.m, oldestKey)
	}
	c.m[cmdID] = cacheEntry{resp: resp, expireAt: now.Add(c.ttl)}
}

func (c *replayCache) size() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.m)
}
