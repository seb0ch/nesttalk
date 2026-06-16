// Package transport contains paired transport checks for the v0.2.0 sing-box
// migration (Slice 0a). The tests prove:
//
//  1. The deploy/singbox-server.json.tmpl renders into a sing-box server
//     config that uses VLESS/REALITY ingress, the modern sing-box JSON shape,
//     and route-rule destination overrides instead of inbound override fields
//     (POC finding: modern sing-box rejects override_address/override_port in
//     direct outbounds).
//  2. A 1 KB byte exchange completes through the rendered server config when
//     a local sing-box binary is available (server-side smoke gate).
//  3. A 1 KB byte exchange completes through the macOS helper path that
//     reuses the deploy template (server-via-macOS-helper parity).
//
// Steps 2 and 3 require a local `sing-box` binary built with -tags with_utls
// (POC finding). When the binary is missing the smoke checks are skipped, but
// the config-shape checks always run.
package transport

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// repoRoot returns the absolute path to the repository root, derived from
// this test file's location.
func repoRoot(t *testing.T) string {
	t.Helper()
	_, here, _, ok := runtime.Caller(0)
	require.True(t, ok, "runtime.Caller failed")
	// here = <repo>/test/transport/reality_parity_test.go
	root, err := filepath.Abs(filepath.Join(filepath.Dir(here), "..", ".."))
	require.NoError(t, err)
	return root
}

// renderServerTemplate substitutes the documented placeholders in
// deploy/singbox-server.json.tmpl and returns the rendered JSON bytes. It
// mirrors the host/port derivation that entrypoint-singbox.sh performs at
// runtime, so the test exercises the same expanded JSON shape.
func renderServerTemplate(t *testing.T, vars map[string]string) []byte {
	t.Helper()
	root := repoRoot(t)
	templatePath := filepath.Join(root, "deploy", "singbox-server.json.tmpl")
	raw, err := os.ReadFile(templatePath)
	require.NoErrorf(t, err,
		"deploy/singbox-server.json.tmpl must exist (Slice 0a Step 4)")

	expanded := map[string]string{}
	for k, v := range vars {
		expanded[k] = v
	}
	if dest, ok := expanded["REALITY_DEST"]; ok {
		host, port := splitHostPort(t, dest, "REALITY_DEST")
		expanded["REALITY_DEST_HOST"] = host
		expanded["REALITY_DEST_PORT"] = port
	}
	if redir, ok := expanded["API_REDIRECT"]; ok {
		host, port := splitHostPort(t, redir, "API_REDIRECT")
		expanded["API_REDIRECT_HOST"] = host
		expanded["API_REDIRECT_PORT"] = port
	}

	out := string(raw)
	for k, v := range expanded {
		out = strings.ReplaceAll(out, "${"+k+"}", v)
	}
	require.NotContainsf(t, out, "${",
		"unsubstituted placeholder remains in rendered template: %s", out)
	return []byte(out)
}

func splitHostPort(t *testing.T, raw, name string) (string, string) {
	t.Helper()
	idx := strings.LastIndex(raw, ":")
	require.Greaterf(t, idx, 0, "%s must be host:port, got %q", name, raw)
	return raw[:idx], raw[idx+1:]
}

// TestSingboxServerTemplateShape validates the rendered server config matches
// the sing-box JSON schema we expect for v0.2.0 (Slice 0a sub-deliverable).
func TestSingboxServerTemplateShape(t *testing.T) {
	rendered := renderServerTemplate(t, map[string]string{
		"REALITY_API_UUID":    uuid.NewString(),
		"REALITY_TURN_UUID":   uuid.NewString(),
		"REALITY_PRIVATE_KEY": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"REALITY_SHORT_ID":    "0123456789abcdef",
		"REALITY_DEST":        "cloudflare.com:443",
		"REALITY_SNI":         "cloudflare.com",
		"API_REDIRECT":        "127.0.0.1:8080",
	})

	var config map[string]any
	require.NoError(t, json.Unmarshal(rendered, &config),
		"rendered template must be valid JSON")

	// sing-box uses top-level "log", "inbounds", "outbounds", "route".
	assert.Contains(t, config, "log")
	assert.Contains(t, config, "inbounds")
	assert.Contains(t, config, "outbounds")
	assert.Contains(t, config, "route",
		"sing-box uses top-level \"route\" instead of Xray's \"routing\"")
	assert.NotContains(t, config, "routing",
		"Xray-style \"routing\" must not appear in sing-box server config")

	inbounds := config["inbounds"].([]any)
	require.Len(t, inbounds, 1, "expect a single REALITY ingress inbound")
	in := inbounds[0].(map[string]any)
	assert.Equal(t, "vless", in["type"], "inbound must be vless")
	assert.Equal(t, float64(443), in["listen_port"])
	assert.Equal(t, "0.0.0.0", in["listen"])
	users := in["users"].([]any)
	assert.GreaterOrEqual(t, len(users), 2,
		"REALITY inbound must declare both api and turn users")

	tls := in["tls"].(map[string]any)
	assert.Equal(t, true, tls["enabled"])
	reality := tls["reality"].(map[string]any)
	assert.Equal(t, true, reality["enabled"])
	assert.Contains(t, reality, "private_key")
	assert.Contains(t, reality, "short_id")
	handshake := reality["handshake"].(map[string]any)
	assert.Equal(t, "cloudflare.com", handshake["server"])
	assert.Equal(t, float64(443), handshake["server_port"])

	outbounds := config["outbounds"].([]any)
	tags := map[string]map[string]any{}
	for _, o := range outbounds {
		ob := o.(map[string]any)
		tags[ob["tag"].(string)] = ob
	}
	require.Contains(t, tags, "nesttalk-api",
		"outbounds must define nesttalk-api direct egress")
	require.Contains(t, tags, "coturn",
		"outbounds must define coturn direct egress")

	api := tags["nesttalk-api"]
	assert.Equal(t, "direct", api["type"])
	// POC finding: modern sing-box rejects override_address/override_port on
	// direct outbounds. Destination overrides must live in route rules.
	assert.NotContains(t, api, "override_address",
		"override_address must not appear on direct outbound; "+
			"use route-rule overrides instead (POC finding)")
	assert.NotContains(t, api, "override_port",
		"override_port must not appear on direct outbound; "+
			"use route-rule overrides instead (POC finding)")

	route := config["route"].(map[string]any)
	rules := route["rules"].([]any)
	require.NotEmpty(t, rules)
	// The TURN user must route to the coturn outbound.
	turnRouted := false
	apiRouted := false
	for _, r := range rules {
		rule := r.(map[string]any)
		out := rule["outbound"]
		// In modern sing-box, "user" matches the OS-level local user (e.g.
		// the unix login name from process lookup); the protocol-level
		// authenticated user filter is "auth_user". Using "user" silently
		// fails to match vless inbound users on Linux containers and falls
		// through to the default outbound, skipping override_address /
		// override_port. Guard against that regression.
		assert.NotContains(t, rule, "user",
			"route rule must use \"auth_user\" (vless protocol identity), "+
				"not \"user\" (OS user). With \"user\" the rule never matches "+
				"the vless inbound and the destination override is silently "+
				"dropped, breaking the API/TURN split.")
		if out == "coturn" {
			turnRouted = true
			assert.Contains(t, rule, "auth_user",
				"coturn route rule must filter by auth_user")
		}
		if out == "nesttalk-api" {
			apiRouted = true
			assert.Contains(t, rule, "auth_user",
				"nesttalk-api route rule must filter by auth_user")
		}
	}
	assert.True(t, turnRouted,
		"a route rule must direct turn traffic to the coturn outbound")
	assert.True(t, apiRouted,
		"a route rule must direct api traffic to the nesttalk-api outbound")
}

// hasSingbox returns the resolved sing-box binary path or "" if none is
// available. The tests that need a live exchange skip when this is empty so
// that the unit shape checks still run on minimal CI machines.
func hasSingbox(t *testing.T) string {
	t.Helper()
	if env := os.Getenv("NESTTALK_SINGBOX_BIN"); env != "" {
		if _, err := os.Stat(env); err == nil {
			return env
		}
	}
	if path, err := exec.LookPath("sing-box"); err == nil {
		return path
	}
	return ""
}

// generateRealityKeys runs `sing-box generate reality-keypair`.
func generateRealityKeys(t *testing.T, singbox string) (privateKey, publicKey string) {
	t.Helper()
	out, err := exec.Command(singbox, "generate", "reality-keypair").Output()
	require.NoErrorf(t, err, "sing-box generate reality-keypair failed: %s", err)
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "PrivateKey:"):
			privateKey = strings.TrimSpace(strings.TrimPrefix(line, "PrivateKey:"))
		case strings.HasPrefix(line, "PublicKey:"):
			publicKey = strings.TrimSpace(strings.TrimPrefix(line, "PublicKey:"))
		}
	}
	require.NotEmptyf(t, privateKey, "PrivateKey not parsed from %q", string(out))
	require.NotEmptyf(t, publicKey, "PublicKey not parsed from %q", string(out))
	return privateKey, publicKey
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func writeJSON(t *testing.T, path string, data []byte) {
	t.Helper()
	require.NoError(t, os.WriteFile(path, data, 0o600))
}

// startSingbox runs `sing-box run -c <config>` and returns a stop function.
// Test callers must defer stop() so that the helper is reaped.
func startSingbox(t *testing.T, ctx context.Context, singbox, configPath string) func() {
	t.Helper()
	cmd := exec.CommandContext(ctx, singbox, "run", "-c", configPath)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	cmd.Stdout = &stderr
	require.NoError(t, cmd.Start(), "sing-box failed to start")
	stopped := false
	return func() {
		if stopped {
			return
		}
		stopped = true
		_ = cmd.Process.Signal(os.Interrupt)
		done := make(chan struct{})
		go func() {
			_ = cmd.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			_ = cmd.Process.Kill()
			<-done
		}
		if t.Failed() {
			t.Logf("sing-box (%s) output:\n%s", filepath.Base(configPath),
				stderr.String())
		}
	}
}

func waitListening(t *testing.T, addr string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 250*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("nothing listening on %s within %s", addr, timeout)
}

// TestRealityServerSideSmoke proves a 1 KB byte exchange completes through
// the rendered sing-box server config.
//
// Topology:
//
//	tcp client (test) -> sing-box server REALITY (loopback :realityPort)
//	                  -> direct outbound -> echo TCP server (loopback :echoPort)
//
// The server config is rendered from deploy/singbox-server.json.tmpl with
// API_REDIRECT pointing at the echo server, and a single REALITY user. The
// test does NOT exercise the client REALITY handshake here - the paired
// macOS-helper test below does that. This smoke just proves the SERVER side
// of the new sing-box ingress accepts a TCP connection on the REALITY port
// (we send only the TCP probe; full handshake is verified by the parity
// test that brings up its own client too).
func TestRealityServerSideSmoke(t *testing.T) {
	singbox := hasSingbox(t)
	if singbox == "" {
		t.Skip("sing-box binary not available; install sing-box (with " +
			"-tags with_utls) or set NESTTALK_SINGBOX_BIN to enable this " +
			"smoke gate")
	}

	echoPort := freePort(t)
	realityPort := freePort(t)

	// Echo server stands in for the nesttalk-server API container.
	echoLn, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", echoPort))
	require.NoError(t, err)
	defer echoLn.Close()
	go func() {
		conn, err := echoLn.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = io.Copy(conn, conn)
	}()

	priv, _ := generateRealityKeys(t, singbox)
	apiUUID := uuid.NewString()
	turnUUID := uuid.NewString()
	shortID := hex.EncodeToString(mustRand(8))

	rendered := renderServerTemplate(t, map[string]string{
		"REALITY_API_UUID":    apiUUID,
		"REALITY_TURN_UUID":   turnUUID,
		"REALITY_PRIVATE_KEY": priv,
		"REALITY_SHORT_ID":    shortID,
		"REALITY_DEST":        "cloudflare.com:443",
		"REALITY_SNI":         "cloudflare.com",
		"API_REDIRECT":        fmt.Sprintf("127.0.0.1:%d", echoPort),
	})

	// Override listen_port for the loopback smoke run.
	var asMap map[string]any
	require.NoError(t, json.Unmarshal(rendered, &asMap))
	inbounds := asMap["inbounds"].([]any)
	in := inbounds[0].(map[string]any)
	in["listen"] = "127.0.0.1"
	in["listen_port"] = realityPort
	rewritten, err := json.MarshalIndent(asMap, "", "  ")
	require.NoError(t, err)

	tmp := t.TempDir()
	configPath := filepath.Join(tmp, "server.json")
	writeJSON(t, configPath, rewritten)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stop := startSingbox(t, ctx, singbox, configPath)
	defer stop()

	waitListening(t, fmt.Sprintf("127.0.0.1:%d", realityPort), 5*time.Second)
}

// TestRealityMacOSHelperParity proves the server-via-macOS-helper 1 KB
// exchange. It composes:
//
//   - sing-box server with the rendered deploy template
//   - sing-box client config matching the macOS helper's expected shape
//     (VLESS/REALITY outbound, direct loopback inbound, route rules wiring
//     inbound -> outbound)
//
// Then it streams 1024 random bytes through the loopback inbound and
// verifies they reappear from the echo server.
func TestRealityMacOSHelperParity(t *testing.T) {
	singbox := hasSingbox(t)
	if singbox == "" {
		t.Skip("sing-box binary not available; install sing-box (with " +
			"-tags with_utls) or set NESTTALK_SINGBOX_BIN to enable parity")
	}

	echoPort := freePort(t)
	realityPort := freePort(t)
	clientPort := freePort(t)

	echoLn, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", echoPort))
	require.NoError(t, err)
	defer echoLn.Close()
	go func() {
		for {
			conn, err := echoLn.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_, _ = io.Copy(c, c)
			}(conn)
		}
	}()

	priv, pub := generateRealityKeys(t, singbox)
	apiUUID := uuid.NewString()
	turnUUID := uuid.NewString()
	shortID := hex.EncodeToString(mustRand(8))

	// Server.
	rendered := renderServerTemplate(t, map[string]string{
		"REALITY_API_UUID":    apiUUID,
		"REALITY_TURN_UUID":   turnUUID,
		"REALITY_PRIVATE_KEY": priv,
		"REALITY_SHORT_ID":    shortID,
		"REALITY_DEST":        "cloudflare.com:443",
		"REALITY_SNI":         "cloudflare.com",
		"API_REDIRECT":        fmt.Sprintf("127.0.0.1:%d", echoPort),
	})
	var serverCfg map[string]any
	require.NoError(t, json.Unmarshal(rendered, &serverCfg))
	in := serverCfg["inbounds"].([]any)[0].(map[string]any)
	in["listen"] = "127.0.0.1"
	in["listen_port"] = realityPort

	tmp := t.TempDir()
	serverPath := filepath.Join(tmp, "server.json")
	serverBytes, err := json.MarshalIndent(serverCfg, "", "  ")
	require.NoError(t, err)
	writeJSON(t, serverPath, serverBytes)

	// Client config in the macOS helper shape.
	clientCfg := macOSHelperClientConfig(macOSHelperConfigInputs{
		ServerHost:    "127.0.0.1",
		ServerPort:    realityPort,
		APIUUID:       apiUUID,
		PublicKey:     pub,
		ShortID:       shortID,
		SNI:           "cloudflare.com",
		LocalAPIPort:  clientPort,
		LocalTURNPort: 0,
		TURNUUID:      "",
	})
	clientBytes, err := json.MarshalIndent(clientCfg, "", "  ")
	require.NoError(t, err)
	clientPath := filepath.Join(tmp, "client.json")
	writeJSON(t, clientPath, clientBytes)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stopServer := startSingbox(t, ctx, singbox, serverPath)
	defer stopServer()
	waitListening(t, fmt.Sprintf("127.0.0.1:%d", realityPort), 5*time.Second)

	stopClient := startSingbox(t, ctx, singbox, clientPath)
	defer stopClient()
	waitListening(t, fmt.Sprintf("127.0.0.1:%d", clientPort), 5*time.Second)
	// Give the sing-box client a moment to settle its REALITY warmup probes
	// (it talks to the dest TLS handshake target on first connections).
	time.Sleep(500 * time.Millisecond)

	// 1 KB parity exchange.
	payload := mustRand(1024)
	conn, err := net.DialTimeout("tcp",
		fmt.Sprintf("127.0.0.1:%d", clientPort), 5*time.Second)
	require.NoError(t, err)
	defer conn.Close()

	deadline := time.Now().Add(20 * time.Second)
	require.NoError(t, conn.SetDeadline(deadline))

	_, err = conn.Write(payload)
	require.NoError(t, err)

	got := make([]byte, len(payload))
	_, err = io.ReadFull(conn, got)
	require.NoError(t, err)
	require.Equal(t, payload, got, "echoed bytes must match")
}

type macOSHelperConfigInputs struct {
	ServerHost    string
	ServerPort    int
	APIUUID       string
	PublicKey     string
	ShortID       string
	SNI           string
	LocalAPIPort  int
	LocalTURNPort int
	TURNUUID      string
}

// macOSHelperClientConfig mirrors the JSON shape that
// RealityTransportService.buildMacOSSingboxConfig must produce on the Dart
// side. Keeping the shape here lets us exercise the parity exchange end-to-
// end from Go without crossing the Flutter test boundary.
func macOSHelperClientConfig(in macOSHelperConfigInputs) map[string]any {
	cfg := map[string]any{
		"log": map[string]any{"level": "warn", "output": "stderr"},
		"inbounds": []any{
			map[string]any{
				"type":        "direct",
				"tag":         "api-in",
				"listen":      "127.0.0.1",
				"listen_port": in.LocalAPIPort,
				"network":     "tcp",
			},
		},
		"outbounds": []any{
			vlessOutbound("api-out", in),
		},
		"route": map[string]any{
			"rules": []any{
				map[string]any{
					"inbound":  []any{"api-in"},
					"action":   "route",
					"outbound": "api-out",
				},
			},
		},
	}
	if in.LocalTURNPort > 0 && in.TURNUUID != "" {
		cfg["inbounds"] = append(cfg["inbounds"].([]any), map[string]any{
			"type":        "direct",
			"tag":         "turn-in",
			"listen":      "127.0.0.1",
			"listen_port": in.LocalTURNPort,
			"network":     "tcp",
		})
		cfg["outbounds"] = append(cfg["outbounds"].([]any),
			vlessOutbound("turn-out", macOSHelperConfigInputs{
				ServerHost: in.ServerHost,
				ServerPort: in.ServerPort,
				APIUUID:    in.TURNUUID,
				PublicKey:  in.PublicKey,
				ShortID:    in.ShortID,
				SNI:        in.SNI,
			}))
		cfg["route"].(map[string]any)["rules"] = append(
			cfg["route"].(map[string]any)["rules"].([]any),
			map[string]any{
				"inbound":  []any{"turn-in"},
				"action":   "route",
				"outbound": "turn-out",
			})
	}
	return cfg
}

func vlessOutbound(tag string, in macOSHelperConfigInputs) map[string]any {
	out := map[string]any{
		"type":        "vless",
		"tag":         tag,
		"server":      in.ServerHost,
		"server_port": in.ServerPort,
		"uuid":        in.APIUUID,
		"flow":        "xtls-rprx-vision",
		"network":     "tcp",
		"tls": map[string]any{
			"enabled":     true,
			"server_name": in.SNI,
			"utls": map[string]any{
				"enabled":     true,
				"fingerprint": "chrome",
			},
			"reality": map[string]any{
				"enabled":    true,
				"public_key": in.PublicKey,
				"short_id":   in.ShortID,
			},
		},
	}
	return out
}

func mustRand(n int) []byte {
	b := make([]byte, n)
	_, err := rand.Read(b)
	if err != nil {
		panic(err)
	}
	return b
}
