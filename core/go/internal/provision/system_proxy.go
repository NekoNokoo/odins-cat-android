package provision

import (
	"fmt"
	"net"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
)

type SystemProxyState struct {
	Supported   bool   `json:"supported"`
	Enabled     bool   `json:"enabled"`
	ServiceName string `json:"serviceName,omitempty"`
	Host        string `json:"host,omitempty"`
	Port        int    `json:"port,omitempty"`
	Error       string `json:"error,omitempty"`
}

func GetSystemProxyState() SystemProxyState {
	if runtime.GOOS != "darwin" {
		return SystemProxyState{Supported: false}
	}

	state, err := currentPrimarySystemProxy()
	if err != nil {
		return SystemProxyState{
			Supported: false,
			Error:     err.Error(),
		}
	}
	state.Supported = true
	return state
}

func EnableSystemProxy(socksAddress string) SystemProxyState {
	if runtime.GOOS != "darwin" {
		return SystemProxyState{Supported: false, Error: "system proxy is supported on macOS only"}
	}

	if strings.TrimSpace(socksAddress) == "" {
		tunnel := GetLocalTunnelState()
		socksAddress = tunnel.SOCKSAddress
	}
	if strings.TrimSpace(socksAddress) == "" {
		return SystemProxyState{Supported: true, Error: "local SOCKS tunnel is not running"}
	}

	host, portText, err := net.SplitHostPort(strings.TrimSpace(socksAddress))
	if err != nil {
		return SystemProxyState{Supported: true, Error: fmt.Sprintf("invalid SOCKS address: %v", err)}
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		return SystemProxyState{Supported: true, Error: fmt.Sprintf("invalid SOCKS port: %v", err)}
	}

	service, err := primaryNetworkService()
	if err != nil {
		return SystemProxyState{Supported: true, Error: err.Error()}
	}

	if _, err := runLocalCommand("networksetup", "-setsocksfirewallproxy", service, host, strconv.Itoa(port)); err != nil {
		return SystemProxyState{Supported: true, Error: err.Error()}
	}
	if _, err := runLocalCommand("networksetup", "-setsocksfirewallproxystate", service, "on"); err != nil {
		return SystemProxyState{Supported: true, Error: err.Error()}
	}

	state, err := socksProxyState(service)
	if err != nil {
		return SystemProxyState{Supported: true, Error: err.Error()}
	}
	state.Supported = true
	if !state.Enabled || !sameProxyEndpoint(state, host, port) {
		state.Error = fmt.Sprintf("system SOCKS proxy did not apply expected address %s:%d on %s", host, port, service)
	}
	return state
}

func DisableSystemProxy() SystemProxyState {
	if runtime.GOOS != "darwin" {
		return SystemProxyState{Supported: false, Error: "system proxy is supported on macOS only"}
	}

	services, err := listNetworkServices()
	if err != nil {
		return SystemProxyState{Supported: true, Error: err.Error()}
	}

	for _, service := range services {
		state, err := socksProxyState(service)
		if err != nil {
			continue
		}
		if state.Enabled && state.Host == "127.0.0.1" {
			_, _ = runLocalCommand("networksetup", "-setsocksfirewallproxystate", service, "off")
		}
	}

	state, err := currentPrimarySystemProxy()
	if err != nil {
		return SystemProxyState{Supported: true, Error: err.Error()}
	}
	state.Supported = true
	if state.Enabled && state.Host == "127.0.0.1" {
		state.Error = "some SOCKS proxy settings are still active"
	}
	return state
}

func currentPrimarySystemProxy() (SystemProxyState, error) {
	service, err := primaryNetworkService()
	if err != nil {
		return SystemProxyState{}, err
	}
	state, err := socksProxyState(service)
	if err != nil {
		return SystemProxyState{}, err
	}
	return state, nil
}

func sameProxyEndpoint(state SystemProxyState, host string, port int) bool {
	return strings.EqualFold(strings.TrimSpace(state.Host), strings.TrimSpace(host)) && state.Port == port
}

func listNetworkServices() ([]string, error) {
	output, err := runLocalCommand("networksetup", "-listallnetworkservices")
	if err != nil {
		return nil, err
	}

	lines := strings.Split(output, "\n")
	services := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "An asterisk") || strings.HasPrefix(line, "*") {
			continue
		}
		services = append(services, line)
	}
	if len(services) == 0 {
		return nil, fmt.Errorf("no network services found")
	}
	return services, nil
}

func primaryNetworkService() (string, error) {
	routeOutput, err := runLocalCommand("route", "-n", "get", "default")
	if err != nil {
		return "", err
	}

	device := ""
	for _, line := range strings.Split(routeOutput, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "interface:") {
			device = strings.TrimSpace(strings.TrimPrefix(line, "interface:"))
			break
		}
	}
	if device == "" {
		services, err := listNetworkServices()
		if err != nil {
			return "", err
		}
		return services[0], nil
	}

	orderOutput, err := runLocalCommand("networksetup", "-listnetworkserviceorder")
	if err != nil {
		return "", err
	}

	blocks := strings.Split(orderOutput, "\n\n")
	for _, block := range blocks {
		block = strings.TrimSpace(block)
		if block == "" || strings.Contains(block, "denotes that a network service is disabled") {
			continue
		}
		lines := strings.Split(block, "\n")
		if len(lines) < 2 {
			continue
		}
		service := strings.TrimSpace(lines[0])
		service = strings.TrimPrefix(service, "(*) ")
		if idx := strings.Index(service, ") "); idx >= 0 {
			service = strings.TrimSpace(service[idx+2:])
		}
		meta := lines[1]
		if strings.Contains(meta, "Device: "+device) {
			return service, nil
		}
	}

	services, err := listNetworkServices()
	if err != nil {
		return "", err
	}
	return services[0], nil
}

func socksProxyState(service string) (SystemProxyState, error) {
	output, err := runLocalCommand("networksetup", "-getsocksfirewallproxy", service)
	if err != nil {
		return SystemProxyState{}, err
	}

	state := SystemProxyState{
		Supported:   true,
		ServiceName: service,
	}
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "Enabled:"):
			state.Enabled = strings.EqualFold(strings.TrimSpace(strings.TrimPrefix(line, "Enabled:")), "Yes")
		case strings.HasPrefix(line, "Server:"):
			state.Host = strings.TrimSpace(strings.TrimPrefix(line, "Server:"))
		case strings.HasPrefix(line, "Port:"):
			port, _ := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "Port:")))
			state.Port = port
		}
	}
	return state, nil
}

func runLocalCommand(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	text := strings.TrimSpace(string(output))
	if err != nil {
		if text == "" {
			text = err.Error()
		}
		return "", fmt.Errorf("%s %s: %s", name, strings.Join(args, " "), text)
	}
	return text, nil
}
