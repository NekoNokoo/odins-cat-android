package provision

import (
	"bytes"
	"fmt"
	"io"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

func connectSSH(req Request) (*ssh.Client, error) {
	address := fmt.Sprintf("%s:%d", req.Server.Host, normalizedPort(req.Server.Port))
	auth, err := buildAuthMethod(req)
	if err != nil {
		return nil, err
	}

	cfg := &ssh.ClientConfig{
		User:            req.Server.Username,
		Auth:            []ssh.AuthMethod{auth},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         8 * time.Second,
	}

	client, err := ssh.Dial("tcp", address, cfg)
	if err != nil {
		return nil, fmt.Errorf("ssh dial failed: %w", err)
	}

	return client, nil
}

func runRemote(client *ssh.Client, cmd string) (string, error) {
	session, err := client.NewSession()
	if err != nil {
		return "", fmt.Errorf("new session: %w", err)
	}
	defer session.Close()

	output, err := session.CombinedOutput(cmd)
	text := strings.TrimSpace(string(output))
	if err != nil {
		if text == "" {
			return "", fmt.Errorf("command %q failed: %w", cmd, err)
		}
		return text, fmt.Errorf("command %q failed: %s", cmd, text)
	}
	return text, nil
}

func uploadFile(client *ssh.Client, remotePath string, data []byte, mode string) error {
	session, err := client.NewSession()
	if err != nil {
		return fmt.Errorf("new upload session: %w", err)
	}
	defer session.Close()

	stdin, err := session.StdinPipe()
	if err != nil {
		return fmt.Errorf("stdin pipe: %w", err)
	}

	var stderr bytes.Buffer
	session.Stderr = &stderr

	go func() {
		_, _ = io.Copy(stdin, bytes.NewReader(data))
		_ = stdin.Close()
	}()

	tmpPath := remotePath + ".tmp-upload"
	cmd := fmt.Sprintf(
		"mkdir -p %s && cat > %s && chmod %s %s && mv -f %s %s",
		quoteShell(dirOf(remotePath)),
		quoteShell(tmpPath),
		mode,
		quoteShell(tmpPath),
		quoteShell(tmpPath),
		quoteShell(remotePath),
	)

	if err := session.Run(cmd); err != nil {
		return fmt.Errorf("upload %s: %w: %s", remotePath, err, strings.TrimSpace(stderr.String()))
	}

	return nil
}

func quoteShell(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func dirOf(path string) string {
	lastSlash := strings.LastIndex(path, "/")
	if lastSlash <= 0 {
		return "."
	}
	return path[:lastSlash]
}
