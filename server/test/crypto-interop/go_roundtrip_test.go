// Package crypto_interop reproduces the v0.2.0 wire envelope from a fixed
// vectors.json file and verifies that the Go implementation produces exactly
// the bytes recorded in the file. The same vectors are consumed by the Dart
// roundtrip test (client/test/crypto_roundtrip_test.dart) so that any byte
// disagreement between the two languages fails CI.
//
// Layout per spec section "Wire envelope (authenticated header + sealed
// payload)":
//
//	0     1   version
//	1     16  sender_user_id (UUID raw)
//	17    16  sender_device_id
//	33    16  recipient_user_id
//	49    16  recipient_device_id
//	65    16  message_id
//	81    32  eph_x25519_pub
//	113   1088 ml_kem_ct
//	1201  12  nonce
//	1213  4   ct_len (uint32 BE)
//	1217  N   ChaCha20-Poly1305 ciphertext+tag
//	1217+N 64 sender_sig (Ed25519 over the first 1217+N bytes)
//
// HKDF info (96 bytes):
//
//	"nesttalk-msg-v1" (15) || version_byte (1) ||
//	  sender_user_id (16) || sender_device_id (16) ||
//	  recipient_user_id (16) || recipient_device_id (16) ||
//	  message_id (16)
//
// IKM = ss_x25519 || ss_ml_kem (32+32 = 64 bytes), salt = 32 zero bytes,
// L = 32 bytes (ChaCha20-Poly1305 key). AAD = the same info bytes.
package crypto_interop

import (
	"bytes"
	"crypto/ed25519"
	"crypto/mlkem"
	"crypto/mlkem/mlkemtest"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
)

const (
	version1     = byte(0x01)
	infoPrefix   = "nesttalk-msg-v1"
	infoLen      = 96
	envelopeMin  = 1297
	chachaKeyLen = 32
)

// vectorsPath resolves to <repo-root>/test/crypto-interop/vectors.json.
func vectorsPath(t *testing.T) string {
	t.Helper()
	cwd, err := os.Getwd()
	require.NoError(t, err)
	// cwd is .../server/test/crypto-interop. Repo root is two parents up.
	root := filepath.Join(cwd, "..", "..", "..")
	return filepath.Join(root, "test", "crypto-interop", "vectors.json")
}

// Vector is one fixture record.
type Vector struct {
	Name              string `json:"name"`
	Version           int    `json:"version"`
	SenderUserID      string `json:"sender_user_id"`
	SenderDeviceID    string `json:"sender_device_id"`
	RecipientUserID   string `json:"recipient_user_id"`
	RecipientDeviceID string `json:"recipient_device_id"`
	MessageID         string `json:"message_id"`

	// 64-byte d||z seed for ML-KEM-768 (NewDecapsulationKey768).
	RecipientMLKEMSeedHex string `json:"recipient_ml_kem_seed_hex"`
	// 32-byte X25519 private key (Curve25519 scalar).
	RecipientX25519PrivHex string `json:"recipient_x25519_priv_hex"`
	// 32-byte Ed25519 seed (NewKeyFromSeed).
	SenderEd25519SeedHex string `json:"sender_ed25519_seed_hex"`
	// 32-byte X25519 ephemeral private key.
	EphX25519PrivHex string `json:"eph_x25519_priv_hex"`
	// 32-byte randomness for Encapsulate768 (mlkemtest derand).
	MLKEMEncapRandHex string `json:"ml_kem_encap_rand_hex"`
	// 12-byte AEAD nonce.
	NonceHex string `json:"nonce_hex"`
	// Plaintext bytes (hex-encoded — empty allowed).
	PlaintextHex string `json:"plaintext_hex"`

	// Derived expected outputs.
	RecipientX25519PubHex string `json:"recipient_x25519_pub_hex"`
	RecipientMLKEMPubHex  string `json:"recipient_ml_kem_pub_hex"`
	SenderEd25519PubHex   string `json:"sender_ed25519_pub_hex"`
	EphX25519PubHex       string `json:"eph_x25519_pub_hex"`
	MLKEMCTHex            string `json:"ml_kem_ct_hex"`
	MLKEMSharedSecretHex  string `json:"ml_kem_shared_secret_hex"`
	X25519SharedSecretHex string `json:"x25519_shared_secret_hex"`
	HKDFInfoHex           string `json:"hkdf_info_hex"`
	SymmetricKeyHex       string `json:"symmetric_key_hex"`
	CiphertextHex         string `json:"ciphertext_hex"`
	EnvelopeHex           string `json:"envelope_hex"`
}

// VectorsFile is the on-disk JSON shape.
type VectorsFile struct {
	SpecVersion int      `json:"spec_version"`
	Comment     string   `json:"comment"`
	Vectors     []Vector `json:"vectors"`
}

// readVectors loads the JSON file. Returns os.ErrNotExist when missing.
func readVectors(t *testing.T) (*VectorsFile, error) {
	t.Helper()
	p := vectorsPath(t)
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, err
	}
	var f VectorsFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("parse %s: %w", p, err)
	}
	return &f, nil
}

func uuidBytes(t *testing.T, s string) []byte {
	t.Helper()
	u, err := uuid.Parse(s)
	require.NoErrorf(t, err, "uuid %q", s)
	return u[:]
}

// buildHKDFInfo returns the 96-byte spec-mandated HKDF info string.
// info = ASCII("nesttalk-msg-v1") || version || sender_user || sender_device
//
//	|| recipient_user || recipient_device || message_id
func buildHKDFInfo(version byte, senderUser, senderDev, recipUser, recipDev, msg []byte) []byte {
	out := make([]byte, 0, infoLen)
	out = append(out, []byte(infoPrefix)...)
	out = append(out, version)
	out = append(out, senderUser...)
	out = append(out, senderDev...)
	out = append(out, recipUser...)
	out = append(out, recipDev...)
	out = append(out, msg...)
	return out
}

// buildEnvelope constructs the wire envelope from primitives. Used both to
// reproduce a vector deterministically and to verify file expectations.
func buildEnvelope(t *testing.T, v Vector) []byte {
	t.Helper()

	// Decode all hex fields.
	mlkemSeed, err := hex.DecodeString(v.RecipientMLKEMSeedHex)
	require.NoError(t, err)
	require.Equal(t, mlkem.SeedSize, len(mlkemSeed), "ml-kem seed must be 64 bytes (d||z)")

	x25519Priv, err := hex.DecodeString(v.RecipientX25519PrivHex)
	require.NoError(t, err)
	require.Equal(t, 32, len(x25519Priv))

	edSeed, err := hex.DecodeString(v.SenderEd25519SeedHex)
	require.NoError(t, err)
	require.Equal(t, ed25519.SeedSize, len(edSeed))

	ephPriv, err := hex.DecodeString(v.EphX25519PrivHex)
	require.NoError(t, err)
	require.Equal(t, 32, len(ephPriv))

	encapRand, err := hex.DecodeString(v.MLKEMEncapRandHex)
	require.NoError(t, err)
	require.Equal(t, 32, len(encapRand))

	nonce, err := hex.DecodeString(v.NonceHex)
	require.NoError(t, err)
	require.Equal(t, chacha20poly1305.NonceSize, len(nonce))

	plaintext, err := hex.DecodeString(v.PlaintextHex)
	require.NoError(t, err)

	// Recipient ML-KEM keypair from seed.
	dk, err := mlkem.NewDecapsulationKey768(mlkemSeed)
	require.NoError(t, err)
	recipMLKEMPub := dk.EncapsulationKey().Bytes()
	require.Equal(t, mlkem.EncapsulationKeySize768, len(recipMLKEMPub))

	// Recipient X25519 public key.
	recipX25519Pub, err := curve25519.X25519(x25519Priv, curve25519.Basepoint)
	require.NoError(t, err)

	// Sender Ed25519 keypair from seed.
	edPriv := ed25519.NewKeyFromSeed(edSeed)
	edPub := edPriv.Public().(ed25519.PublicKey)

	// Ephemeral X25519 public key.
	ephPub, err := curve25519.X25519(ephPriv, curve25519.Basepoint)
	require.NoError(t, err)

	// Encapsulate against recipient's ML-KEM public key with fixed
	// randomness so the CT is deterministic across re-runs.
	ek, err := mlkem.NewEncapsulationKey768(recipMLKEMPub)
	require.NoError(t, err)
	ssMLKEM, mlkemCT, err := mlkemtest.Encapsulate768(ek, encapRand)
	require.NoError(t, err)
	require.Equal(t, mlkem.CiphertextSize768, len(mlkemCT))
	require.Equal(t, mlkem.SharedKeySize, len(ssMLKEM))

	// Recipient-side decapsulation must match the same shared secret.
	ssCheck, err := dk.Decapsulate(mlkemCT)
	require.NoError(t, err)
	require.Equal(t, ssMLKEM, ssCheck, "decap must match encap shared secret")

	// X25519 ECDH: recipient priv * eph pub == eph priv * recipient pub
	// (Diffie-Hellman). Sender uses eph priv * recipient pub.
	ssX, err := curve25519.X25519(ephPriv, recipX25519Pub)
	require.NoError(t, err)
	require.Equal(t, 32, len(ssX))

	// HKDF info.
	info := buildHKDFInfo(
		byte(v.Version),
		uuidBytes(t, v.SenderUserID),
		uuidBytes(t, v.SenderDeviceID),
		uuidBytes(t, v.RecipientUserID),
		uuidBytes(t, v.RecipientDeviceID),
		uuidBytes(t, v.MessageID),
	)
	require.Equal(t, infoLen, len(info), "HKDF info must be 96 bytes")

	// IKM = ss_x25519 || ss_ml_kem (X25519 first, then PQ — spec normative).
	ikm := append(append([]byte(nil), ssX...), ssMLKEM...)
	salt := make([]byte, 32) // 32 zero bytes per spec.

	r := hkdf.New(sha256.New, ikm, salt, info)
	key := make([]byte, chachaKeyLen)
	_, err = r.Read(key)
	require.NoError(t, err)

	// AEAD seal.
	aead, err := chacha20poly1305.New(key)
	require.NoError(t, err)
	ct := aead.Seal(nil, nonce, plaintext, info)

	// Build envelope (everything before signature).
	body := bytes.NewBuffer(nil)
	body.WriteByte(byte(v.Version))
	body.Write(uuidBytes(t, v.SenderUserID))
	body.Write(uuidBytes(t, v.SenderDeviceID))
	body.Write(uuidBytes(t, v.RecipientUserID))
	body.Write(uuidBytes(t, v.RecipientDeviceID))
	body.Write(uuidBytes(t, v.MessageID))
	body.Write(ephPub)
	body.Write(mlkemCT)
	body.Write(nonce)
	var ctLen [4]byte
	binary.BigEndian.PutUint32(ctLen[:], uint32(len(ct)))
	body.Write(ctLen[:])
	body.Write(ct)

	signed := body.Bytes()
	sig := ed25519.Sign(edPriv, signed)
	require.Equal(t, ed25519.SignatureSize, len(sig))

	// Cross-check exposed fields if the vector recorded them.
	if v.RecipientX25519PubHex != "" {
		require.Equal(t, v.RecipientX25519PubHex, hex.EncodeToString(recipX25519Pub))
	}
	if v.RecipientMLKEMPubHex != "" {
		require.Equal(t, v.RecipientMLKEMPubHex, hex.EncodeToString(recipMLKEMPub))
	}
	if v.SenderEd25519PubHex != "" {
		require.Equal(t, v.SenderEd25519PubHex, hex.EncodeToString(edPub))
	}
	if v.EphX25519PubHex != "" {
		require.Equal(t, v.EphX25519PubHex, hex.EncodeToString(ephPub))
	}
	if v.MLKEMCTHex != "" {
		require.Equal(t, v.MLKEMCTHex, hex.EncodeToString(mlkemCT))
	}
	if v.MLKEMSharedSecretHex != "" {
		require.Equal(t, v.MLKEMSharedSecretHex, hex.EncodeToString(ssMLKEM))
	}
	if v.X25519SharedSecretHex != "" {
		require.Equal(t, v.X25519SharedSecretHex, hex.EncodeToString(ssX))
	}
	if v.HKDFInfoHex != "" {
		require.Equal(t, v.HKDFInfoHex, hex.EncodeToString(info))
	}
	if v.SymmetricKeyHex != "" {
		require.Equal(t, v.SymmetricKeyHex, hex.EncodeToString(key))
	}
	if v.CiphertextHex != "" {
		require.Equal(t, v.CiphertextHex, hex.EncodeToString(ct))
	}

	envelope := append(signed, sig...)
	require.GreaterOrEqual(t, len(envelope), envelopeMin,
		"envelope must satisfy spec minimum 1297 bytes")
	return envelope
}

// TestVectorsRoundtrip is the cross-language gate. The vectors.json file is
// committed and read by both Go and Dart tests; both languages must reproduce
// envelope_hex bit-for-bit.
func TestVectorsRoundtrip(t *testing.T) {
	f, err := readVectors(t)
	require.NoError(t, err, "vectors file missing — generate via TestGenerateVectors")
	require.NotEmpty(t, f.Vectors, "vectors file must contain at least one vector")

	for _, v := range f.Vectors {
		v := v
		t.Run(v.Name, func(t *testing.T) {
			got := buildEnvelope(t, v)
			gotHex := hex.EncodeToString(got)
			require.Equal(t, v.EnvelopeHex, gotHex,
				"envelope mismatch for %q — Dart implementations rely on this byte vector",
				v.Name)
		})
	}
}

// TestGenerateVectors writes vectors.json from a fixed input set when the
// environment variable NESTTALK_GENERATE_VECTORS=1 is set. This avoids
// rewriting the file on every CI run while still allowing intentional
// regeneration via `NESTTALK_GENERATE_VECTORS=1 go test ./server/test/crypto-interop/...`.
func TestGenerateVectors(t *testing.T) {
	if os.Getenv("NESTTALK_GENERATE_VECTORS") != "1" {
		t.Skip("set NESTTALK_GENERATE_VECTORS=1 to regenerate")
	}

	// Fixed inputs. UUIDs chosen to include at least one with
	// time_hi_and_version > 0x7F (the third group's first nibble) to catch
	// endianness regressions in 16-byte UUID encoding.
	inputs := []struct {
		name      string
		version   int
		senderU   string
		senderD   string
		recipU    string
		recipD    string
		msg       string
		mlkemSeed []byte
		x25519    []byte
		edSeed    []byte
		ephPriv   []byte
		encapRand []byte
		nonce     []byte
		plaintext []byte
	}{
		{
			name:      "hello",
			version:   1,
			senderU:   "11111111-2222-3333-4444-555555555555",
			senderD:   "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
			recipU:    "12345678-9abc-def0-1234-56789abcdef0",
			recipD:    "0fedcba9-8765-4321-fedc-ba9876543210",
			msg:       "deadbeef-dead-beef-dead-beefdeadbeef",
			mlkemSeed: fillSeed(0x10, 64),
			x25519:    fillSeed(0x20, 32),
			edSeed:    fillSeed(0x30, 32),
			ephPriv:   fillSeed(0x40, 32),
			encapRand: fillSeed(0x50, 32),
			nonce:     fillSeed(0x60, 12),
			plaintext: []byte("hello, family!"),
		},
		{
			name:      "empty_plaintext",
			version:   1,
			senderU:   "fedcba98-7654-3210-fedc-ba9876543210",
			senderD:   "01020304-0506-0708-090a-0b0c0d0e0f10",
			recipU:    "abcdef01-2345-6789-abcd-ef0123456789",
			recipD:    "00112233-4455-6677-8899-aabbccddeeff",
			msg:       "ffffffff-eeee-dddd-cccc-bbbbaaaa9999",
			mlkemSeed: fillSeed(0x70, 64),
			x25519:    fillSeed(0x80, 32),
			edSeed:    fillSeed(0x90, 32),
			ephPriv:   fillSeed(0xA0, 32),
			encapRand: fillSeed(0xB0, 32),
			nonce:     fillSeed(0xC0, 12),
			plaintext: []byte{},
		},
	}

	out := VectorsFile{
		SpecVersion: 1,
		Comment:     "Generated by go_roundtrip_test.go (TestGenerateVectors). Do NOT edit by hand. Re-generate with NESTTALK_GENERATE_VECTORS=1.",
	}

	for _, in := range inputs {
		v := Vector{
			Name:                  in.name,
			Version:               in.version,
			SenderUserID:          in.senderU,
			SenderDeviceID:        in.senderD,
			RecipientUserID:       in.recipU,
			RecipientDeviceID:     in.recipD,
			MessageID:             in.msg,
			RecipientMLKEMSeedHex: hex.EncodeToString(in.mlkemSeed),
			RecipientX25519PrivHex: hex.EncodeToString(in.x25519),
			SenderEd25519SeedHex:   hex.EncodeToString(in.edSeed),
			EphX25519PrivHex:       hex.EncodeToString(in.ephPriv),
			MLKEMEncapRandHex:      hex.EncodeToString(in.encapRand),
			NonceHex:               hex.EncodeToString(in.nonce),
			PlaintextHex:           hex.EncodeToString(in.plaintext),
		}
		// Run buildEnvelope to populate derived hex outputs by re-running.
		populateDerived(t, &v)
		out.Vectors = append(out.Vectors, v)
	}

	b, err := json.MarshalIndent(out, "", "  ")
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(vectorsPath(t), b, 0o644))
}

// populateDerived computes the expected envelope and intermediate derived
// values for the given vector and writes them into v. Mirror of buildEnvelope
// but without require.Equal assertions on the (currently empty) derived hex
// fields.
func populateDerived(t *testing.T, v *Vector) {
	mlkemSeed, _ := hex.DecodeString(v.RecipientMLKEMSeedHex)
	dk, err := mlkem.NewDecapsulationKey768(mlkemSeed)
	require.NoError(t, err)
	recipMLKEMPub := dk.EncapsulationKey().Bytes()

	x25519Priv, _ := hex.DecodeString(v.RecipientX25519PrivHex)
	recipX25519Pub, err := curve25519.X25519(x25519Priv, curve25519.Basepoint)
	require.NoError(t, err)

	edSeed, _ := hex.DecodeString(v.SenderEd25519SeedHex)
	edPriv := ed25519.NewKeyFromSeed(edSeed)
	edPub := edPriv.Public().(ed25519.PublicKey)

	ephPriv, _ := hex.DecodeString(v.EphX25519PrivHex)
	ephPub, err := curve25519.X25519(ephPriv, curve25519.Basepoint)
	require.NoError(t, err)

	encapRand, _ := hex.DecodeString(v.MLKEMEncapRandHex)
	ek, err := mlkem.NewEncapsulationKey768(recipMLKEMPub)
	require.NoError(t, err)
	ssMLKEM, mlkemCT, err := mlkemtest.Encapsulate768(ek, encapRand)
	require.NoError(t, err)

	ssX, err := curve25519.X25519(ephPriv, recipX25519Pub)
	require.NoError(t, err)

	info := buildHKDFInfo(
		byte(v.Version),
		uuidBytes(t, v.SenderUserID),
		uuidBytes(t, v.SenderDeviceID),
		uuidBytes(t, v.RecipientUserID),
		uuidBytes(t, v.RecipientDeviceID),
		uuidBytes(t, v.MessageID),
	)
	ikm := append(append([]byte(nil), ssX...), ssMLKEM...)
	salt := make([]byte, 32)
	r := hkdf.New(sha256.New, ikm, salt, info)
	key := make([]byte, chachaKeyLen)
	_, _ = r.Read(key)

	nonce, _ := hex.DecodeString(v.NonceHex)
	plaintext, _ := hex.DecodeString(v.PlaintextHex)
	aead, err := chacha20poly1305.New(key)
	require.NoError(t, err)
	ct := aead.Seal(nil, nonce, plaintext, info)

	body := bytes.NewBuffer(nil)
	body.WriteByte(byte(v.Version))
	body.Write(uuidBytes(t, v.SenderUserID))
	body.Write(uuidBytes(t, v.SenderDeviceID))
	body.Write(uuidBytes(t, v.RecipientUserID))
	body.Write(uuidBytes(t, v.RecipientDeviceID))
	body.Write(uuidBytes(t, v.MessageID))
	body.Write(ephPub)
	body.Write(mlkemCT)
	body.Write(nonce)
	var ctLen [4]byte
	binary.BigEndian.PutUint32(ctLen[:], uint32(len(ct)))
	body.Write(ctLen[:])
	body.Write(ct)

	signed := body.Bytes()
	sig := ed25519.Sign(edPriv, signed)

	v.RecipientX25519PubHex = hex.EncodeToString(recipX25519Pub)
	v.RecipientMLKEMPubHex = hex.EncodeToString(recipMLKEMPub)
	v.SenderEd25519PubHex = hex.EncodeToString(edPub)
	v.EphX25519PubHex = hex.EncodeToString(ephPub)
	v.MLKEMCTHex = hex.EncodeToString(mlkemCT)
	v.MLKEMSharedSecretHex = hex.EncodeToString(ssMLKEM)
	v.X25519SharedSecretHex = hex.EncodeToString(ssX)
	v.HKDFInfoHex = hex.EncodeToString(info)
	v.SymmetricKeyHex = hex.EncodeToString(key)
	v.CiphertextHex = hex.EncodeToString(ct)
	v.EnvelopeHex = hex.EncodeToString(append(signed, sig...))
}

func fillSeed(start byte, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = start + byte(i)
	}
	return out
}
