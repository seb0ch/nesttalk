// nesttalk-server is the long-lived daemon that owns the SQLite database
// and serves both the HTTP/WS client API and the Unix-domain-socket admin
// RPC. See the v0.2.0 spec for the full surface.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/seb0ch/nesttalk/server/internal/auth"
	"github.com/seb0ch/nesttalk/server/internal/backup"
	"github.com/seb0ch/nesttalk/server/internal/calls"
	"github.com/seb0ch/nesttalk/server/internal/control"
	"github.com/seb0ch/nesttalk/server/internal/keys"
	"github.com/seb0ch/nesttalk/server/internal/messages"
	"github.com/seb0ch/nesttalk/server/internal/push"
	"github.com/seb0ch/nesttalk/server/internal/reactions"
	"github.com/seb0ch/nesttalk/server/internal/roster"
	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/trace"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

func main() {
	dbPath := flag.String("db", envOrDefault("DB_PATH", "/var/lib/nesttalk/nesttalk.db"), "sqlite path")
	httpAddr := flag.String("http", envOrDefault("HTTP_ADDR", ":8080"), "http listen address")
	socketPath := flag.String("control-socket", envOrDefault("CONTROL_SOCKET", "/var/run/nesttalk/control.sock"), "admin RPC unix socket path")
	flag.Parse()

	db, err := storage.Open(*dbPath)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer db.Close()

	authSvc := auth.New(db)
	rosterSvc := roster.New(db)
	keysSvc := keys.New(db)
	hub := ws.NewHub()
	messagesSvc := messages.New(db, hub)
	reactionsSvc := reactions.New(db, hub)
	typingTracker := messages.NewTypingTracker(hub, nil)
	callsMgr := calls.New(db, hub)
	callsMgr.TURNSecret = os.Getenv("TURN_SECRET")
	callsMgr.TURNHost = envOrDefault("TURN_HOST", "localhost")
	// Replay call state to a freshly-registered WS session: active ring
	// first, then call_state_changed snapshots (covers terminal events
	// missed while offline), then queued SDP/ICE signals.
	hub.OnRegister = callsMgr.OnWSRegister

	// Optional APNs VoIP push wiring. When the four NESTTALK_APNS_*
	// env vars are set and the .p8 key contents are readable, every
	// callsMgr.Create fans out a VoIP push to the callee's last-
	// registered device — the only mechanism that can wake a
	// terminated iOS app to ring CallKit on the lock screen. Absent
	// any one of them: server runs fine, only WS-delivered ringing
	// works (good enough for macOS + foreground iOS).
	if devClient, prodClient, err := buildAPNsClients(); err != nil {
		log.Printf("nesttalk-server: APNs client disabled: %v", err)
	} else if devClient != nil && prodClient != nil {
		callsMgr.VoIPPush = func(callID, fromUserID, fromName, kind, toUserID string) {
			ctx2, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			// Read through the CURRENT DB pointer, not the captured startup
			// handle: an admin restore/vacuum closes the original handle and
			// swaps a fresh one into callsMgr.DB. Using `db` here would query
			// a closed handle and silently drop the push after a restore.
			token, env, err := lookupVoIPToken(ctx2, callsMgr.DB, toUserID)
			if err != nil || token == "" {
				return
			}
			// Route to the host matching the token's registered environment;
			// a mismatched host is rejected by Apple and never wakes the app.
			client := devClient
			if env == "prod" {
				client = prodClient
			}
			payload := push.NewVoIPPayload(callID, fromUserID, fromName, kind)
			res, err := client.Send(ctx2, token, payload)
			if err != nil {
				log.Printf("nesttalk-server: APNs send failed for %s (env=%s): %v", toUserID, env, err)
				return
			}
			// Send returns nil error for APNs HTTP rejections — inspect the
			// status. A non-2xx push never wakes the app, so log it instead of
			// silently treating it as delivered.
			if res.StatusCode/100 != 2 {
				log.Printf("nesttalk-server: APNs rejected push for %s (env=%s): status=%d reason=%q apns-id=%s",
					toUserID, env, res.StatusCode, res.Reason, res.APNSID)
				// A token Apple says is dead (410 Unregistered, or a bad/topic-
				// mismatched token) will never work again — clear it so we stop
				// pushing to it and the client re-registers on next launch. Bind
				// the clear to THIS token so a freshly re-registered one isn't
				// wiped by a late rejection of the old token.
				if res.StatusCode == http.StatusGone ||
					res.Reason == "BadDeviceToken" ||
					res.Reason == "Unregistered" ||
					res.Reason == "DeviceTokenNotForTopic" {
					if cerr := clearVoIPToken(ctx2, callsMgr.DB, toUserID, token); cerr != nil {
						log.Printf("nesttalk-server: clear stale VoIP token for %s failed: %v", toUserID, cerr)
					}
				}
			}
		}
		log.Printf("nesttalk-server: APNs VoIP push enabled (dev + prod routing)")
	}

	allowedOrigins := parseAllowedOrigins(os.Getenv("NESTTALK_ALLOWED_ORIGINS"))

	deps := &Deps{
		DB:             db,
		Auth:           authSvc,
		Roster:         rosterSvc,
		Keys:           keysSvc,
		Messages:       messagesSvc,
		Reactions:      reactionsSvc,
		Calls:          callsMgr,
		Hub:            hub,
		Typing:         typingTracker,
		AllowedOrigins: allowedOrigins,
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Startup sweep: transition stale ringing→missed and connected→ended(stale_sweep)
	// before opening the HTTP listener (spec: "before HTTP listen").
	if n, err := callsMgr.RunStartupSweep(context.Background()); err != nil {
		log.Printf("nesttalk-server: startup sweep error: %v", err)
	} else if n > 0 {
		log.Printf("nesttalk-server: startup sweep transitioned %d stale calls", n)
	}

	// Start the message purge job (5-minute interval per spec).
	go messagesSvc.RunForever(ctx, 5*time.Minute)

	// Ringing-timeout sweep: unanswered calls transition to missed.
	// Without this, a stale `ringing` row blocks the pair's future
	// calls via glare detection until a restart.
	go callsMgr.RunMissedSweepForever(ctx, 5*time.Second)

	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	// Always assign a correlation trace-id (W3C traceparent) per request;
	// only LOG per-request lines + trace.Logf detail when NESTTALK_DEBUG is set.
	debugLog := os.Getenv("NESTTALK_DEBUG") != ""
	trace.SetDebug(debugLog)
	if debugLog {
		log.Printf("nesttalk-server: NESTTALK_DEBUG set — per-request HTTP logging enabled (metadata only, trace-correlated)")
	}
	httpSrv := &http.Server{
		Addr:              *httpAddr,
		Handler:           withTrace(mux, debugLog),
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctrl := control.New(db, authSvc)
	ctrl.Backup = newDaemonBackupRunner(deps, ctrl, *dbPath)
	ctrl.Calls = callsMgr
	ctrl.Sessions = hub // drop live WS sessions on revoke
	if err := os.MkdirAll(parentDir(*socketPath), 0o755); err != nil {
		log.Printf("control socket dir: %v", err)
	}
	_ = os.Remove(*socketPath) // stale-socket cleanup
	if err := ctrl.Listen(*socketPath); err != nil {
		log.Fatalf("control listen: %v", err)
	}

	go func() {
		log.Printf("nesttalk-server: http listening on %s", *httpAddr)
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("http: %v", err)
		}
	}()
	go func() {
		log.Printf("nesttalk-server: control socket listening on %s", *socketPath)
		if err := ctrl.ServeAccept(ctx); err != nil {
			log.Printf("control accept: %v", err)
		}
	}()

	<-ctx.Done()
	log.Printf("nesttalk-server: shutting down")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	_ = httpSrv.Shutdown(shutdownCtx)
	_ = ctrl.Close()
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// parseAllowedOrigins resolves the NESTTALK_ALLOWED_ORIGINS env var
// into the OriginPatterns slice used by the WebSocket Accept call.
//
// Empty defaults to loopback + the *.nesttalk.local dev domain so the
// macOS/iOS Flutter clients (which connect through a local sing-box
// helper terminating loopback HTTP, Origin = http://127.0.0.1:<port>)
// can complete the handshake out of the box. A startup warning is
// emitted in that case so production deployments override it.

// daemonBackupRunner adapts the backup service to the long-lived daemon's
// mutable *storage.DB pointer. The mutex serializes restore calls and
// gates BackupTo behind a snapshot of the current DB; restore swaps the
// pointer in-place under the lock so subsequent handlers see the freshly
// reopened handle.
type daemonBackupRunner struct {
	mu   sync.Mutex
	deps *Deps
	ctrl *control.Server // rebound on restore/vacuum so admin RPCs don't use a closed DB
	path string
	svc  *backup.Service
}

func newDaemonBackupRunner(deps *Deps, ctrl *control.Server, dbPath string) *daemonBackupRunner {
	return &daemonBackupRunner{deps: deps, ctrl: ctrl, path: dbPath, svc: backup.New()}
}

func (r *daemonBackupRunner) BackupTo(ctx context.Context, dest string) error {
	r.mu.Lock()
	current := r.deps.DB
	r.mu.Unlock()
	return r.svc.BackupTo(ctx, current, dest)
}

// Vacuum closes the live DB connection, runs SQLite VACUUM on a fresh
// dedicated connection in autocommit mode (SQLite forbids VACUUM inside
// any transaction), then reopens the daemon's DB pointer via the same
// reopener used by RestoreFrom so all deps see the freshly-rewritten file.
//
// IMPORTANT: run backup-to before vacuum — VACUUM rewrites the entire file
// and is not transactional; a crash mid-vacuum leaves the file in an
// undefined state.
func (r *daemonBackupRunner) Vacuum(ctx context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	// Close the live connection pool before VACUUM so the WAL is
	// checkpointed cleanly and no writer is in flight.
	path := r.path
	if err := r.deps.DB.Close(); err != nil {
		return fmt.Errorf("vacuum: close db: %w", err)
	}

	if err := storage.Vacuum(ctx, path); err != nil {
		// Best effort: try to reopen even if VACUUM failed so the
		// daemon stays alive. If reopen also fails the daemon must
		// be restarted.
		fresh, _ := storage.Open(path)
		if fresh != nil {
			r.deps.DB = fresh
			r.deps.Auth.DB = fresh
			r.deps.Roster.DB = fresh
			r.deps.Keys.DB = fresh
			r.deps.Messages.DB = fresh
			r.deps.Reactions.DB = fresh
			r.deps.Calls.DB = fresh
			r.ctrl.DB = fresh // admin RPCs (enroll/revoke/list/vacuum) must not hit the closed handle
		}
		return fmt.Errorf("vacuum: %w", err)
	}

	fresh, err := storage.Open(path)
	if err != nil {
		return fmt.Errorf("vacuum: reopen: %w", err)
	}
	r.deps.DB = fresh
	r.deps.Auth.DB = fresh
	r.deps.Roster.DB = fresh
	r.deps.Keys.DB = fresh
	r.deps.Messages.DB = fresh
	r.deps.Reactions.DB = fresh
	r.deps.Calls.DB = fresh
	r.ctrl.DB = fresh // admin RPCs (enroll/revoke/list/vacuum) must not hit the closed handle
	return nil
}

func (r *daemonBackupRunner) RestoreFrom(ctx context.Context, src string) (int64, string, int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	reopen := backup.ReopenerFunc(func(ctx context.Context) (*storage.DB, error) {
		return storage.Open(r.path)
	})
	fresh, result, err := r.svc.RestoreFrom(ctx, r.deps.DB, r.path, src, reopen, r.deps.Hub)
	if err != nil {
		return 0, "", 0, err
	}
	// Swap every dependency that captured the old *storage.DB pointer.
	//
	// KNOWN RACE (acceptable for Slice 1c, must be tightened in Slice 2):
	// in-flight HTTP handlers that already dereferenced r.deps.{Auth,Roster,
	// Keys}.DB hold a pointer to the now-closed storage.DB. Their next
	// query returns sql.ErrConnDone — the request fails but no data is
	// corrupted. The server_restored broadcast that just fired forces every
	// connected client to re-handshake, so the failure window is bounded
	// to the few pre-restore in-flight requests. Slice 2 is expected to
	// add an explicit "stop accepting writes" barrier (e.g. an atomic
	// generation pointer that handlers re-read before each query), at
	// which point this comment can be removed.
	r.deps.DB = fresh
	r.deps.Auth.DB = fresh
	r.deps.Roster.DB = fresh
	r.deps.Keys.DB = fresh
	r.deps.Messages.DB = fresh
	r.deps.Reactions.DB = fresh
	r.deps.Calls.DB = fresh
	r.ctrl.DB = fresh // admin RPCs (enroll/revoke/list/vacuum) must not hit the closed handle
	return result.Generation, result.JWTKid, result.BroadcastCount, nil
}

func parseAllowedOrigins(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		log.Printf("nesttalk-server: NESTTALK_ALLOWED_ORIGINS unset; defaulting to loopback + *.nesttalk.local (development)")
		// The macOS/iOS sing-box helper terminates loopback HTTP on
		// arbitrary ports, so the patterns must include a wildcard
		// port. path.Match treats ':' as a literal and '*' as "any
		// non-slash characters", so "127.0.0.1:*" matches "127.0.0.1:34567".
		return []string{
			"localhost", "localhost:*",
			"127.0.0.1", "127.0.0.1:*",
			"[::1]", "[::1]:*",
			"*.nesttalk.local", "*.nesttalk.local:*",
		}
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// (see buildAPNsClients below for the dev+prod construction.)
//
// Env contract:
//
//	NESTTALK_APNS_KEY_P8_PATH   path to the .p8 file (preferred for podman secret mounts)
//	NESTTALK_APNS_KEY_P8        OR raw .p8 contents inline (less secure)
//	NESTTALK_APNS_KEY_ID        10-char Key ID
//	NESTTALK_APNS_TEAM_ID       10-char Team ID (Q2GZ8F5NV5 for NestTalk)
//	NESTTALK_APNS_TOPIC_VOIP    "<bundle-id>.voip" (e.g., com.nesttalk.ios.voip)
//
// The host is no longer configured: both sandbox and production clients are
// built and the per-device registered env routes each push to the right one.
//
// buildAPNsClients builds BOTH the sandbox (dev) and production APNs clients
// from a single JWT, so a push can be routed to the host matching the stored
// per-device token environment. A dev token sent to prod (or vice versa) is
// silently rejected by Apple and never wakes the app, so the env must drive
// host selection rather than one server-wide endpoint.
func buildAPNsClients() (dev, prod *push.Client, err error) {
	keyID := os.Getenv("NESTTALK_APNS_KEY_ID")
	teamID := os.Getenv("NESTTALK_APNS_TEAM_ID")
	topic := os.Getenv("NESTTALK_APNS_TOPIC_VOIP")
	if keyID == "" && teamID == "" && topic == "" {
		return nil, nil, nil // not configured; opt-in feature
	}
	if keyID == "" || teamID == "" || topic == "" {
		return nil, nil, fmt.Errorf("partial APNs config — set all of NESTTALK_APNS_{KEY_ID,TEAM_ID,TOPIC_VOIP}")
	}
	var keyBytes []byte
	if path := os.Getenv("NESTTALK_APNS_KEY_P8_PATH"); path != "" {
		b, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil, nil, fmt.Errorf("read APNs .p8 from %s: %w", path, readErr)
		}
		keyBytes = b
	} else if inline := os.Getenv("NESTTALK_APNS_KEY_P8"); inline != "" {
		keyBytes = []byte(inline)
	} else {
		return nil, nil, fmt.Errorf("NESTTALK_APNS_KEY_P8_PATH or NESTTALK_APNS_KEY_P8 required")
	}
	jwt, err := push.NewJWTCache(keyBytes, keyID, teamID)
	if err != nil {
		return nil, nil, fmt.Errorf("apns jwt: %w", err)
	}
	if dev, err = push.NewClient(jwt, push.APNSDevHost, topic); err != nil {
		return nil, nil, fmt.Errorf("apns dev client: %w", err)
	}
	if prod, err = push.NewClient(jwt, push.APNSProdHost, topic); err != nil {
		return nil, nil, fmt.Errorf("apns prod client: %w", err)
	}
	return dev, prod, nil
}

// lookupVoIPToken reads the recipient's most-recently-registered VoIP
// push token from `devices`. v0.4.0 enforces single-active-device per
// user, so the latest non-revoked row is the one to wake.
func lookupVoIPToken(ctx context.Context, db *storage.DB, userID string) (string, string, error) {
	var token, env string
	err := db.QueryRowContext(ctx,
		`SELECT COALESCE(voip_push_token, ''), COALESCE(voip_push_env, '')
		   FROM devices
		  WHERE user_id = ? AND revoked_at IS NULL
		  ORDER BY enrolled_at DESC
		  LIMIT 1`,
		userID,
	).Scan(&token, &env)
	if err != nil {
		return "", "", err
	}
	return token, env, nil
}

// clearVoIPToken drops a VoIP token Apple reported as permanently dead. The
// match on the exact token value avoids wiping a token the client may have
// freshly re-registered between our send and this late rejection.
func clearVoIPToken(ctx context.Context, db *storage.DB, userID, token string) error {
	_, err := db.ExecContext(ctx,
		`UPDATE devices SET voip_push_token = NULL, voip_push_env = NULL
		  WHERE user_id = ? AND revoked_at IS NULL AND voip_push_token = ?`,
		userID, token,
	)
	return err
}

func parentDir(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' {
			return p[:i]
		}
	}
	return "."
}
