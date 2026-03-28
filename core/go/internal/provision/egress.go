package provision

import (
	"os/exec"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

const (
	defaultProbeHTTPURL  = "http://example.com"
	defaultProbeHTTPSURL = "https://example.com"
)

func runRemoteEgressChecks(client *ssh.Client) ([]Check, bool) {
	specs := []struct {
		key   string
		label string
		cmd   string
	}{
		{
			key:   "curl-presence",
			label: "Curl availability",
			cmd:   "command -v curl",
		},
		{
			key:   "dns-resolution",
			label: "DNS resolution",
			cmd:   "getent ahostsv4 example.com | head -n 1 || getent hosts example.com | head -n 1",
		},
		{
			key:   "remote-http-egress",
			label: "Remote HTTP egress",
			cmd:   "curl -4 -fsSI --connect-timeout 5 --max-time 12 " + quoteShell(defaultProbeHTTPURL) + " | head -n 1",
		},
		{
			key:   "remote-https-egress",
			label: "Remote HTTPS egress",
			cmd:   "curl -4 -fsSI --connect-timeout 5 --max-time 12 " + quoteShell(defaultProbeHTTPSURL) + " | head -n 1",
		},
	}

	checks := make([]Check, 0, len(specs))
	allOK := true
	for _, spec := range specs {
		output, err := runRemote(client, spec.cmd)
		ok := err == nil
		detail := strings.TrimSpace(output)
		if err != nil {
			ok = false
			if detail == "" {
				detail = err.Error()
			}
		}
		if detail == "" {
			detail = "No output"
		}
		checks = append(checks, Check{
			Key:    spec.key,
			Label:  spec.label,
			OK:     ok,
			Detail: detail,
		})
		allOK = allOK && ok
	}

	return checks, allOK
}

func runSOCKSProbe(socksAddress, url string, connectTimeout, maxTime int) *LocalTunnelTestResult {
	if strings.TrimSpace(url) == "" {
		url = defaultProbeHTTPSURL
	}

	cmd := exec.Command(
		"curl",
		"--connect-timeout", itoa(connectTimeout),
		"--max-time", itoa(maxTime),
		"--socks5-hostname", socksAddress,
		"-I",
		url,
	)
	output, err := cmd.CombinedOutput()

	result := &LocalTunnelTestResult{
		OK:        err == nil,
		Status:    "passed",
		URL:       url,
		Output:    strings.TrimSpace(string(output)),
		CheckedAt: time.Now().UTC().Format(time.RFC3339),
	}
	if err != nil {
		result.OK = false
		result.Status = "failed"
		result.Error = err.Error()
	}
	return result
}

func itoa(value int) string {
	return strconv.Itoa(value)
}
