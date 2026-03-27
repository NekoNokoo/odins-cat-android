package provision

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"

	"golang.org/x/crypto/curve25519"
)

type wireGuardKeyPair struct {
	Private string
	Public  string
}

func generateWireGuardKeyPair() (wireGuardKeyPair, error) {
	privateKey := make([]byte, 32)
	if _, err := rand.Read(privateKey); err != nil {
		return wireGuardKeyPair{}, fmt.Errorf("generate private key: %w", err)
	}

	privateKey[0] &= 248
	privateKey[31] = (privateKey[31] & 127) | 64

	publicKey, err := curve25519.X25519(privateKey, curve25519.Basepoint)
	if err != nil {
		return wireGuardKeyPair{}, fmt.Errorf("derive public key: %w", err)
	}

	return wireGuardKeyPair{
		Private: base64.StdEncoding.EncodeToString(privateKey),
		Public:  base64.StdEncoding.EncodeToString(publicKey),
	}, nil
}
