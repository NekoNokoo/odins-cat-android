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
	DeployFlow   string              `json:"deployFlow,omitempty"`
	User         string              `json:"user"`
	AuthMethod   string              `json:"authMethod"`
	EdgeEnabled  bool                `json:"edgeEnabled,omitempty"`
	EdgeHost     string              `json:"edgeHost,omitempty"`
	EdgePort     int                 `json:"edgePort,omitempty"`
	Checks       []Check             `json:"checks"`
	Warnings     []string            `json:"warnings"`
	ProtocolPack []ProtocolPackEntry `json:"protocolPack,omitempty"`
	Error        string              `json:"error,omitempty"`
}

func Validate(req Request) ValidationResponse {
	flow := normalizedProvisionFlow(req.Flow)
	protocolPackFallbacks := previewProtocolPackFallbacks("", 0)
	if req.Edge != nil && req.Edge.Enabled {
		protocolPackFallbacks = previewProtocolPackFallbacks(req.Edge.Server.Host, normalizedEdgePublicPort(req.Edge))
	}
	resp := ValidationResponse{
		Host:         req.Server.Host,
		DeployFlow:   string(flow),
		User:         req.Server.Username,
		AuthMethod:   string(req.Server.AuthMethod),
		Warnings:     buildPlanWarnings(req, flow),
		ProtocolPack: buildProtocolPackWithFallbacks(
			TransportXray,
			0,
			req.Server.RealityPort,
			req.Server.VKTurnProxyPort,
			protocolPackFallbacks,
		),
	}
	if req.Edge != nil && req.Edge.Enabled {
		resp.EdgeEnabled = true
		resp.EdgeHost = req.Edge.Server.Host
		resp.EdgePort = normalizedEdgePublicPort(req.Edge)
	}

	if req.Server.Host == "" || req.Server.Username == "" || req.Secret == "" {
		resp.Error = "host, username, and secret are required"
		return resp
	}
	if flow == ProvisionFlowEdgeAttach {
		if err := validateEdgeAttachRequest(req); err != nil {
			resp.Error = err.Error()
			return resp
		}
		return validateEdgeAttach(req, resp)
	}
	if err := validateDeploymentPortHints(req.Server); err != nil {
		resp.Error = err.Error()
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

func validateEdgeAttach(req Request, resp ValidationResponse) ValidationResponse {
	originClient, err := connectSSH(req)
	if err != nil {
		resp.Error = fmt.Sprintf("origin ssh dial failed: %v", err)
		return resp
	}
	defer originClient.Close()

	resp.Checks = append(resp.Checks,
		Check{
			Key:    "origin-tcp-connect",
			Label:  "Origin TCP connectivity",
			OK:     true,
			Detail: fmt.Sprintf("Connected to %s:%d", req.Server.Host, normalizedPort(req.Server.Port)),
		},
	)
	if _, _, _, err := loadRemoteAccessState(originClient); err != nil {
		resp.Checks = append(resp.Checks, Check{
			Key:    "origin-owner-profile",
			Label:  "Origin owner profile",
			OK:     false,
			Detail: err.Error(),
		})
		resp.Error = "origin owner profile is not ready for edge attach"
		return resp
	}
	resp.Checks = append(resp.Checks, Check{
		Key:    "origin-owner-profile",
		Label:  "Origin owner profile",
		OK:     true,
		Detail: "Loaded the live owner profile and REALITY state from the origin host.",
	})

	edgeClient, err := connectSSH(edgeRequest(req))
	if err != nil {
		resp.Error = fmt.Sprintf("edge ssh dial failed: %v", err)
		return resp
	}
	defer edgeClient.Close()

	resp.Checks = append(resp.Checks, Check{
		Key:    "edge-tcp-connect",
		Label:  "Edge TCP connectivity",
		OK:     true,
		Detail: fmt.Sprintf("Connected to %s:%d", req.Edge.Server.Host, normalizedPort(req.Edge.Server.Port)),
	})

	results := []struct {
		key   string
		label string
		cmd   string
	}{
		{"edge-remote-user", "Edge remote user", "whoami"},
		{"edge-os-release", "Edge operating system", "uname -a"},
		{"edge-sudo-presence", "Edge sudo availability", "command -v sudo && sudo -n true && echo ready"},
	}

	allOK := true
	for _, item := range results {
		output, runErr := runRemote(edgeClient, item.cmd)
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

	publicPort := normalizedEdgePublicPort(req.Edge)
	_, portErr := runRemote(edgeClient, remoteRootShell(fmt.Sprintf("if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|\\]|:)%d$'; then exit 1; fi", publicPort)))
	portDetail := fmt.Sprintf("%d/tcp is currently free on the edge host", publicPort)
	if portErr != nil {
		portDetail = portErr.Error()
	}
	resp.Checks = append(resp.Checks, Check{
		Key:    "edge-public-port",
		Label:  "Edge public port",
		OK:     portErr == nil,
		Detail: portDetail,
	})
	allOK = allOK && portErr == nil

	resp.OK = allOK
	if !allOK {
		resp.Error = "one or more validation checks failed"
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
