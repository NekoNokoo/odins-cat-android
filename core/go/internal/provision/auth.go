package provision

import (
	"fmt"

	"golang.org/x/crypto/ssh"
)

func buildAuthMethod(req Request) (ssh.AuthMethod, error) {
	switch req.Server.AuthMethod {
	case AuthPassword:
		return ssh.Password(req.Secret), nil
	case AuthPrivateKey:
		signer, err := ssh.ParsePrivateKey([]byte(req.Secret))
		if err != nil {
			return nil, fmt.Errorf("parse private key: %w", err)
		}
		return ssh.PublicKeys(signer), nil
	default:
		return nil, fmt.Errorf("unsupported auth method: %s", req.Server.AuthMethod)
	}
}
