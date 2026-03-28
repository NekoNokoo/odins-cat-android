package provision

import (
	"fmt"
	"net"
	"strings"
	"time"
)

type Check struct {
	Key    string `json:"key"`
	Label  string `json:"label"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

type ValidationResponse struct {
	OK           bool                `json:"ok"`
	Host         string              `json:"host"`
	User         string              `json:"user"`
	AuthMethod   string              `json:"authMethod"`
	Checks       []Check             `json:"checks"`
	Warnings     []string            `json:"warnings"`
	ProtocolPack []ProtocolPackEntry `json:"protocolPack,omitempty"`
	Error        string              `json:"error,omitempty"`
}

func Validate(req Request) ValidationResponse {
	resp := ValidationResponse{
		Host:       req.Server.Host,
		User:       req.Server.Username,
		AuthMethod: string(req.Server.AuthMethod),
		Warnings: []string{
			"MVP validation currently uses insecure host key acceptance and should be hardened before production use.",
			"Odin One keeps the current localhost-first data path while staging a future protocol pack for Russia-friendly TCP and UDP fallbacks.",
		},
		ProtocolPack: buildProtocolPack(req.Server.Transport, 0),
	}

	if req.Server.Host == "" || req.Server.Username == "" || req.Secret == "" {
		resp.Error = "host, username, and secret are required"
		return resp
	}

	address := fmt.Sprintf("%s:%d", req.Server.Host, normalizedPort(req.Server.Port))
	client, err := connectSSH(req)
	if err != nil {
		resp.Error = fmt.Sprintf("ssh dial failed: %v", err)
		return resp
	}
	defer client.Close()

	resp.Checks = append(resp.Checks, Check{
		Key:    "tcp-connect",
		Label:  "TCP connectivity",
		OK:     true,
		Detail: fmt.Sprintf("Connected to %s", address),
	})

	results := []struct {
		key   string
		label string
		cmd   string
	}{
		{"remote-user", "Remote user", "whoami"},
		{"os-release", "Operating system", "uname -a"},
		{"sudo-presence", "Sudo availability", "command -v sudo || true"},
		{"docker-presence", "Docker presence", "command -v docker || true"},
	}

	allOK := true
	for _, item := range results {
		output, runErr := runRemote(client, item.cmd)
		checkOK := runErr == nil
		detail := output
		if runErr != nil {
			checkOK = false
			detail = runErr.Error()
		}
		if strings.TrimSpace(detail) == "" {
			detail = "No output"
		}
		resp.Checks = append(resp.Checks, Check{
			Key:    item.key,
			Label:  item.label,
			OK:     checkOK,
			Detail: detail,
		})
		allOK = allOK && checkOK
	}

	portOpen := Check{
		Key:    "ssh-port",
		Label:  "SSH port reachable",
		OK:     true,
		Detail: fmt.Sprintf("%d/tcp accepted the connection", normalizedPort(req.Server.Port)),
	}
	resp.Checks = append([]Check{portOpen}, resp.Checks...)

	egressChecks, egressOK := runRemoteEgressChecks(client)
	resp.Checks = append(resp.Checks, egressChecks...)

	resp.OK = allOK && egressOK
	if !allOK && resp.Error == "" {
		resp.Error = "one or more validation checks failed"
	}
	if !egressOK && resp.Error == "" {
		resp.Error = "remote egress checks failed"
	}

	return resp
}

func normalizedPort(port int) int {
	if port == 0 {
		return 22
	}
	return port
}

func canDial(address string) bool {
	conn, err := net.DialTimeout("tcp", address, 4*time.Second)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
