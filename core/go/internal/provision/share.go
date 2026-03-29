package provision

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

const shareCodePrefix = "odin1:"

type inviteProfile struct {
	ID              string `json:"id,omitempty"`
	Role            string `json:"role"`
	Name            string `json:"name"`
	Protocol        string `json:"protocol"`
	Transport       string `json:"transport"`
	ServerHost      string `json:"serverHost"`
	VKTurnProxyPort int    `json:"vkTurnProxyPort"`
	EndpointPort    int    `json:"endpointPort,omitempty"`
	Endpoint        string `json:"endpoint"`
	Fingerprint     string `json:"fingerprint"`
	CreatedAt       string `json:"createdAt,omitempty"`
	RevokedAt       string `json:"revokedAt,omitempty"`
	Status          string `json:"status,omitempty"`
	WireGuard       struct {
		ServerPublicKey  string `json:"serverPublicKey"`
		ClientPrivateKey string `json:"clientPrivateKey"`
		ClientPublicKey  string `json:"clientPublicKey"`
		Address          string `json:"address"`
		MTU              int    `json:"mtu"`
	} `json:"wireguard"`
	VLESSReality struct {
		Port       int    `json:"port"`
		ServerName string `json:"serverName"`
		PublicKey  string `json:"publicKey"`
		ShortID    string `json:"shortId"`
		UUID       string `json:"uuid"`
		Flow       string `json:"flow"`
	} `json:"vlessReality,omitempty"`
	StagedFallbacks map[string]any `json:"stagedFallbacks,omitempty"`
}

type InviteProfileResponse struct {
	ID              string `json:"id,omitempty"`
	Role            string `json:"role"`
	Name            string `json:"name"`
	Protocol        string `json:"protocol"`
	Transport       string `json:"transport"`
	ServerHost      string `json:"serverHost"`
	VKTurnProxyPort int    `json:"vkTurnProxyPort"`
	EndpointPort    int    `json:"endpointPort,omitempty"`
	Endpoint        string `json:"endpoint"`
	Fingerprint     string `json:"fingerprint"`
	VLESSReality    struct {
		Port       int    `json:"port"`
		ServerName string `json:"serverName"`
		PublicKey  string `json:"publicKey"`
		ShortID    string `json:"shortId"`
		UUID       string `json:"uuid"`
		Flow       string `json:"flow"`
	} `json:"vlessReality,omitempty"`
	ShareCode  string `json:"shareCode"`
	RawJSON    string `json:"rawJson"`
	LocalPath  string `json:"localPath,omitempty"`
	ImportedAt string `json:"importedAt,omitempty"`
	CreatedAt  string `json:"createdAt,omitempty"`
	RevokedAt  string `json:"revokedAt,omitempty"`
	Status     string `json:"status,omitempty"`
	Error      string `json:"error,omitempty"`
}

func GenerateGuestInvite(host, name string) InviteProfileResponse {
	_ = host
	_ = name
	return InviteProfileResponse{
		Error: "guest access keys must be issued remotely so each device gets its own transport identity",
	}
}

func ImportInvite(shareCode string) InviteProfileResponse {
	invite, rawJSON, err := decodeInvite(shareCode)
	if err != nil {
		return InviteProfileResponse{Error: err.Error()}
	}

	targetPath, err := localImportedProfilePath(invite.ServerHost, invite.Name, invite.Fingerprint)
	if err != nil {
		return InviteProfileResponse{Error: err.Error()}
	}
	if err := os.WriteFile(targetPath, []byte(rawJSON), 0o600); err != nil {
		return InviteProfileResponse{Error: fmt.Sprintf("save imported profile: %v", err)}
	}

	resp := buildInviteResponse(invite, targetPath)
	resp.ImportedAt = time.Now().UTC().Format(time.RFC3339)
	return resp
}

func GetImportedInvite(host string) InviteProfileResponse {
	invite, localPath, err := findLocalImportedInvite(host, "")
	if err != nil {
		return InviteProfileResponse{Error: err.Error()}
	}
	return buildInviteResponse(invite, localPath)
}

func buildInviteResponse(invite inviteProfile, localPath string) InviteProfileResponse {
	raw, _ := json.MarshalIndent(invite, "", "  ")
	return InviteProfileResponse{
		ID:              invite.ID,
		Role:            invite.Role,
		Name:            invite.Name,
		Protocol:        invite.Protocol,
		Transport:       invite.Transport,
		ServerHost:      invite.ServerHost,
		VKTurnProxyPort: invite.VKTurnProxyPort,
		EndpointPort:    invite.EndpointPort,
		Endpoint:        invite.Endpoint,
		Fingerprint:     invite.Fingerprint,
		VLESSReality:    invite.VLESSReality,
		ShareCode:       shareCodePrefix + base64.RawURLEncoding.EncodeToString(raw),
		RawJSON:         string(raw),
		LocalPath:       localPath,
		CreatedAt:       invite.CreatedAt,
		RevokedAt:       invite.RevokedAt,
		Status:          invite.Status,
	}
}

func decodeInvite(shareCode string) (inviteProfile, string, error) {
	var invite inviteProfile

	rawText := strings.TrimSpace(shareCode)
	if rawText == "" {
		return invite, "", fmt.Errorf("share code is required")
	}

	if strings.HasPrefix(rawText, shareCodePrefix) {
		decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(rawText, shareCodePrefix))
		if err != nil {
			return invite, "", fmt.Errorf("decode share code: %w", err)
		}
		rawText = string(decoded)
	}

	if err := json.Unmarshal([]byte(rawText), &invite); err != nil {
		return invite, "", fmt.Errorf("parse invite profile: %w", err)
	}
	invite.Protocol = normalizedInviteProtocol(invite)
	if invite.VLESSReality.Flow == "" && invite.Protocol == string(ProtocolVLESSReality) {
		invite.VLESSReality.Flow = "xtls-rprx-vision"
	}
	if err := validateInvite(invite); err != nil {
		return invite, "", err
	}

	normalized, err := json.MarshalIndent(invite, "", "  ")
	if err != nil {
		return invite, "", fmt.Errorf("normalize invite profile: %w", err)
	}
	return invite, string(normalized), nil
}

func normalizedInviteProtocol(invite inviteProfile) string {
	switch strings.TrimSpace(invite.Protocol) {
	case string(ProtocolVLESSReality), "wireguard":
		return strings.TrimSpace(invite.Protocol)
	case string(ProtocolDirectWireGuard):
		return "wireguard"
	}
	if inviteHasReality(invite) {
		return string(ProtocolVLESSReality)
	}
	return "wireguard"
}

func inviteHasWireGuard(invite inviteProfile) bool {
	return strings.TrimSpace(invite.WireGuard.ServerPublicKey) != "" &&
		strings.TrimSpace(invite.WireGuard.ClientPrivateKey) != "" &&
		strings.TrimSpace(invite.WireGuard.ClientPublicKey) != ""
}

func inviteHasReality(invite inviteProfile) bool {
	return invite.VLESSReality.Port > 0 &&
		strings.TrimSpace(invite.VLESSReality.ServerName) != "" &&
		strings.TrimSpace(invite.VLESSReality.PublicKey) != "" &&
		strings.TrimSpace(invite.VLESSReality.ShortID) != "" &&
		strings.TrimSpace(invite.VLESSReality.UUID) != ""
}

func inviteIdentityValue(invite inviteProfile) string {
	if strings.TrimSpace(invite.VLESSReality.UUID) != "" {
		return invite.VLESSReality.UUID
	}
	return invite.WireGuard.ClientPublicKey
}

func validateInvite(invite inviteProfile) error {
	if strings.TrimSpace(invite.Name) == "" {
		return fmt.Errorf("invite profile name is required")
	}
	if strings.TrimSpace(invite.ServerHost) == "" {
		return fmt.Errorf("invite profile serverHost is required")
	}
	if effectiveInviteEndpointPort(invite) <= 0 {
		return fmt.Errorf("invite profile endpointPort is required")
	}
	if strings.TrimSpace(invite.Transport) == "" {
		return fmt.Errorf("invite profile transport is required")
	}
	switch normalizedInviteProtocol(invite) {
	case "wireguard":
		if strings.TrimSpace(invite.WireGuard.ServerPublicKey) == "" || strings.TrimSpace(invite.WireGuard.ClientPrivateKey) == "" {
			return fmt.Errorf("invite profile wireguard keys are required")
		}
	case string(ProtocolVLESSReality):
		if !inviteHasReality(invite) {
			return fmt.Errorf("invite profile VLESS + REALITY settings are required")
		}
	default:
		return fmt.Errorf("invite profile protocol %q is not supported", invite.Protocol)
	}
	return nil
}

func ListRemoteGuestProfiles(req Request) ([]InviteProfileResponse, error) {
	client, err := connectSSH(req)
	if err != nil {
		return nil, err
	}
	defer client.Close()

	owner, _, xrayState, err := loadRemoteAccessState(client)
	if err != nil {
		return nil, err
	}

	guestProfiles, err := readRemoteGuestProfiles(client)
	if err != nil {
		return nil, err
	}

	items := make([]InviteProfileResponse, 0, len(guestProfiles))
	for _, guest := range guestProfiles {
		enrichInviteProfile(&guest, owner, xrayState)
		items = append(items, buildInviteResponse(guest, ""))
	}

	sort.Slice(items, func(i, j int) bool {
		return items[i].Name < items[j].Name
	})

	return items, nil
}

func IssueRemoteGuestProfile(req Request, name string) (InviteProfileResponse, error) {
	client, err := connectSSH(req)
	if err != nil {
		return InviteProfileResponse{}, err
	}
	defer client.Close()

	owner, _, xrayState, err := loadRemoteAccessState(client)
	if err != nil {
		return InviteProfileResponse{}, err
	}

	guestProfiles, err := readRemoteGuestProfiles(client)
	if err != nil {
		return InviteProfileResponse{}, err
	}

	if owner.Transport != string(TransportXray) {
		return InviteProfileResponse{}, fmt.Errorf("VLESS + REALITY guest access keys require the direct xray transport")
	}
	if xrayState.Reality.Port <= 0 || strings.TrimSpace(xrayState.Reality.PrivateKey) == "" || strings.TrimSpace(owner.VLESSReality.PublicKey) == "" {
		return InviteProfileResponse{}, fmt.Errorf("remote VLESS + REALITY inbound is not available for guest access keys")
	}

	guestUUID, err := generateProtocolUUID()
	if err != nil {
		return InviteProfileResponse{}, err
	}

	guestID := nextGuestID(guestProfiles)
	guest := inviteProfile{
		ID:              guestID,
		Role:            "guest",
		Name:            defaultInviteName(name),
		Protocol:        string(ProtocolVLESSReality),
		Transport:       owner.Transport,
		ServerHost:      owner.ServerHost,
		VKTurnProxyPort: owner.VKTurnProxyPort,
		EndpointPort:    xrayState.Reality.Port,
		Endpoint:        fmt.Sprintf("%s:%d", owner.ServerHost, xrayState.Reality.Port),
		CreatedAt:       nowRFC3339(),
		Status:          "active",
	}
	guest.VLESSReality.UUID = guestUUID
	guest.VLESSReality.Flow = "xtls-rprx-vision"
	enrichInviteProfile(&guest, owner, xrayState)

	rawJSON, err := json.MarshalIndent(guest, "", "  ")
	if err != nil {
		return InviteProfileResponse{}, fmt.Errorf("marshal guest profile: %w", err)
	}

	if err := uploadFile(client, remoteGuestProfilePath(guest.ID), rawJSON, "0600"); err != nil {
		return InviteProfileResponse{}, err
	}

	guestProfiles = append(guestProfiles, guest)
	if err := syncRemoteXrayConfig(client, owner, xrayState, guestProfiles); err != nil {
		return InviteProfileResponse{}, err
	}

	return buildInviteResponse(guest, ""), nil
}

func RevokeRemoteGuestProfile(req Request, guestID string) (InviteProfileResponse, error) {
	client, err := connectSSH(req)
	if err != nil {
		return InviteProfileResponse{}, err
	}
	defer client.Close()

	owner, _, xrayState, err := loadRemoteAccessState(client)
	if err != nil {
		return InviteProfileResponse{}, err
	}

	guestProfiles, err := readRemoteGuestProfiles(client)
	if err != nil {
		return InviteProfileResponse{}, err
	}

	var target *inviteProfile
	for index := range guestProfiles {
		if guestProfiles[index].ID == guestID {
			target = &guestProfiles[index]
			break
		}
	}
	if target == nil {
		return InviteProfileResponse{}, fmt.Errorf("guest profile %q not found", guestID)
	}

	target.Status = "revoked"
	target.RevokedAt = nowRFC3339()
	enrichInviteProfile(target, owner, xrayState)

	rawJSON, err := json.MarshalIndent(target, "", "  ")
	if err != nil {
		return InviteProfileResponse{}, fmt.Errorf("marshal revoked guest profile: %w", err)
	}
	if err := uploadFile(client, remoteGuestProfilePath(target.ID), rawJSON, "0600"); err != nil {
		return InviteProfileResponse{}, err
	}

	if err := syncRemoteXrayConfig(client, owner, xrayState, guestProfiles); err != nil {
		return InviteProfileResponse{}, err
	}

	return buildInviteResponse(*target, ""), nil
}

func defaultInviteName(name string) string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return "Odin One Guest"
	}
	return trimmed
}

func inviteFingerprint(host string, port int, serverPublicKey string) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s|%d|%s", host, port, serverPublicKey)))
	return hex.EncodeToString(sum[:8])
}

func localImportedProfilesDir() (string, error) {
	root, err := appCacheDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(root, "imports")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

func localImportedProfilePath(host, name, fingerprint string) (string, error) {
	dir, err := localImportedProfilesDir()
	if err != nil {
		return "", err
	}
	fileName := fmt.Sprintf("%s-%s-%s.json", sanitizeHost(host), sanitizeHost(name), sanitizeHost(fingerprint))
	return filepath.Join(dir, fileName), nil
}

func findLocalImportedInvite(host string, transport string) (inviteProfile, string, error) {
	var matched inviteProfile

	dir, err := localImportedProfilesDir()
	if err != nil {
		return matched, "", err
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return matched, "", err
	}

	trimmedHost := strings.TrimSpace(host)
	trimmedTransport := strings.TrimSpace(transport)
	matchCount := 0
	matchPath := ""

	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}

		path := filepath.Join(dir, entry.Name())
		body, err := os.ReadFile(path)
		if err != nil {
			continue
		}

		var invite inviteProfile
		if err := json.Unmarshal(body, &invite); err != nil {
			continue
		}
		if err := validateInvite(invite); err != nil {
			continue
		}
		if trimmedHost != "" && invite.ServerHost != trimmedHost {
			continue
		}
		if trimmedTransport != "" && invite.Transport != trimmedTransport {
			continue
		}

		matched = invite
		matchPath = path
		matchCount++
	}

	switch {
	case matchCount == 0 && trimmedHost != "":
		return matched, "", fmt.Errorf("no imported profile found for host %q", trimmedHost)
	case matchCount == 0:
		return matched, "", fmt.Errorf("no imported profile found")
	case matchCount > 1 && trimmedHost == "":
		return matched, "", fmt.Errorf("multiple imported profiles found; choose a server first")
	default:
		return matched, matchPath, nil
	}
}

type remoteXrayState struct {
	WireGuardPort int
	SecretKey     string
	Reality       remoteRealityState
}

type remoteRealityState struct {
	Port       int
	PrivateKey string
	ServerName string
	ShortID    string
	Dest       string
}

func readInviteRealityFallback(invite inviteProfile) (realityFallback, error) {
	if inviteHasReality(invite) {
		flow := strings.TrimSpace(invite.VLESSReality.Flow)
		if flow == "" {
			flow = "xtls-rprx-vision"
		}
		return realityFallback{
			Port:       invite.VLESSReality.Port,
			ServerName: invite.VLESSReality.ServerName,
			PublicKey:  invite.VLESSReality.PublicKey,
			ShortID:    invite.VLESSReality.ShortID,
			UUID:       invite.VLESSReality.UUID,
			Flow:       flow,
		}, nil
	}

	raw, ok := invite.StagedFallbacks["vlessReality"]
	if !ok {
		return realityFallback{}, fmt.Errorf("invite profile has no VLESS + REALITY settings")
	}
	data, err := json.Marshal(raw)
	if err != nil {
		return realityFallback{}, fmt.Errorf("marshal invite reality config: %w", err)
	}
	var parsed struct {
		Port       int    `json:"port"`
		ServerName string `json:"serverName"`
		PublicKey  string `json:"publicKey"`
		ShortID    string `json:"shortId"`
		UUID       string `json:"uuid"`
		Flow       string `json:"flow"`
	}
	if err := json.Unmarshal(data, &parsed); err != nil {
		return realityFallback{}, fmt.Errorf("parse invite reality config: %w", err)
	}
	if parsed.Port <= 0 || parsed.ServerName == "" || parsed.PublicKey == "" || parsed.ShortID == "" || parsed.UUID == "" {
		return realityFallback{}, fmt.Errorf("invite profile has incomplete VLESS + REALITY settings")
	}
	if parsed.Flow == "" {
		parsed.Flow = "xtls-rprx-vision"
	}
	return realityFallback{
		Port:       parsed.Port,
		ServerName: parsed.ServerName,
		PublicKey:  parsed.PublicKey,
		ShortID:    parsed.ShortID,
		UUID:       parsed.UUID,
		Flow:       parsed.Flow,
	}, nil
}

func readRemoteGuestProfiles(client *ssh.Client) ([]inviteProfile, error) {
	output, err := runRemote(client, fmt.Sprintf("find %s -maxdepth 1 -type f -name '*.json' | sort", quoteShell(whitelistGuestProfilesDir)))
	if err != nil {
		if strings.Contains(err.Error(), "No such file") {
			return nil, nil
		}
		return nil, err
	}
	if strings.TrimSpace(output) == "" {
		return nil, nil
	}

	paths := strings.Split(strings.TrimSpace(output), "\n")
	guestProfiles := make([]inviteProfile, 0, len(paths))
	for _, path := range paths {
		body, err := runRemote(client, "cat "+quoteShell(strings.TrimSpace(path)))
		if err != nil {
			return nil, err
		}
		var guest inviteProfile
		if err := json.Unmarshal([]byte(body), &guest); err != nil {
			return nil, fmt.Errorf("parse guest profile %s: %w", path, err)
		}
		guestProfiles = append(guestProfiles, guest)
	}
	return guestProfiles, nil
}

func loadRemoteAccessState(client *ssh.Client) (inviteProfile, string, remoteXrayState, error) {
	var owner inviteProfile
	var xrayState remoteXrayState

	ownerText, err := runRemote(client, "cat "+quoteShell(ownerProfileRemotePath))
	if err != nil {
		return owner, "", xrayState, err
	}
	if err := json.Unmarshal([]byte(ownerText), &owner); err != nil {
		return owner, "", xrayState, fmt.Errorf("parse remote owner profile: %w", err)
	}
	if reality, err := readInviteRealityFallback(owner); err == nil {
		owner.VLESSReality.Port = reality.Port
		owner.VLESSReality.ServerName = reality.ServerName
		owner.VLESSReality.PublicKey = reality.PublicKey
		owner.VLESSReality.ShortID = reality.ShortID
		owner.VLESSReality.UUID = reality.UUID
		owner.VLESSReality.Flow = reality.Flow
		owner.Protocol = string(ProtocolVLESSReality)
	} else {
		owner.Protocol = normalizedInviteProtocol(owner)
	}

	xrayText, err := runRemote(client, "cat "+quoteShell(whitelistXrayConfigPath))
	if err != nil {
		return owner, ownerText, xrayState, err
	}

	var parsed struct {
		Inbounds []struct {
			Tag      string `json:"tag"`
			Protocol string `json:"protocol"`
			Port     int    `json:"port"`
			Settings struct {
				SecretKey string `json:"secretKey"`
			} `json:"settings"`
			StreamSettings struct {
				RealitySettings struct {
					Dest        string   `json:"dest"`
					PrivateKey  string   `json:"privateKey"`
					ServerNames []string `json:"serverNames"`
					ShortIDs    []string `json:"shortIds"`
				} `json:"realitySettings"`
			} `json:"streamSettings"`
		} `json:"inbounds"`
	}
	if err := json.Unmarshal([]byte(xrayText), &parsed); err != nil {
		return owner, ownerText, xrayState, fmt.Errorf("parse remote xray config: %w", err)
	}
	if len(parsed.Inbounds) == 0 {
		return owner, ownerText, xrayState, fmt.Errorf("remote xray config has no inbounds")
	}

	for _, inbound := range parsed.Inbounds {
		switch inbound.Protocol {
		case "wireguard":
			xrayState.WireGuardPort = inbound.Port
			xrayState.SecretKey = inbound.Settings.SecretKey
		case "vless":
			xrayState.Reality.Port = inbound.Port
			xrayState.Reality.PrivateKey = inbound.StreamSettings.RealitySettings.PrivateKey
			xrayState.Reality.Dest = inbound.StreamSettings.RealitySettings.Dest
			if len(inbound.StreamSettings.RealitySettings.ServerNames) > 0 {
				xrayState.Reality.ServerName = inbound.StreamSettings.RealitySettings.ServerNames[0]
			}
			if len(inbound.StreamSettings.RealitySettings.ShortIDs) > 0 {
				xrayState.Reality.ShortID = inbound.StreamSettings.RealitySettings.ShortIDs[0]
			}
		}
	}
	if xrayState.WireGuardPort == 0 {
		return owner, ownerText, xrayState, fmt.Errorf("remote xray config has no wireguard inbound")
	}
	if owner.EndpointPort == 0 {
		if owner.Transport == string(TransportXray) {
			owner.EndpointPort = xrayState.WireGuardPort
		} else {
			owner.EndpointPort = owner.VKTurnProxyPort
		}
	}
	return owner, ownerText, xrayState, nil
}

func syncRemoteXrayConfig(client *ssh.Client, owner inviteProfile, xrayState remoteXrayState, guests []inviteProfile) error {
	peers := []xrayWireGuardPeer{
		{
			PublicKey:  owner.WireGuard.ClientPublicKey,
			AllowedIPs: []string{owner.WireGuard.Address},
		},
	}
	realityClients := make([]xrayRealityClient, 0, len(guests)+1)
	if reality, err := readInviteRealityFallback(owner); err == nil {
		realityClients = append(realityClients, xrayRealityClient{
			UUID: reality.UUID,
			Flow: reality.Flow,
		})
	}

	for _, guest := range guests {
		if guest.Status == "revoked" || guest.RevokedAt != "" {
			continue
		}
		if inviteHasWireGuard(guest) {
			peers = append(peers, xrayWireGuardPeer{
				PublicKey:  guest.WireGuard.ClientPublicKey,
				AllowedIPs: []string{guest.WireGuard.Address},
			})
		}
		if reality, err := readInviteRealityFallback(guest); err == nil {
			realityClients = append(realityClients, xrayRealityClient{
				UUID: reality.UUID,
				Flow: reality.Flow,
			})
		}
	}

	listenHost := "127.0.0.1"
	if owner.Transport == string(TransportXray) {
		listenHost = "0.0.0.0"
	}
	var realityInbound *xrayRealityInbound
	if xrayState.Reality.Port > 0 && strings.TrimSpace(xrayState.Reality.PrivateKey) != "" && len(realityClients) > 0 {
		realityInbound = &xrayRealityInbound{
			Port:       xrayState.Reality.Port,
			Clients:    realityClients,
			PrivateKey: xrayState.Reality.PrivateKey,
			ShortID:    xrayState.Reality.ShortID,
			ServerName: xrayState.Reality.ServerName,
			Dest:       xrayState.Reality.Dest,
		}
	}
	config := renderXrayConfigWithListen(xrayState.SecretKey, peers, listenHost, xrayState.WireGuardPort, realityInbound)
	if err := uploadFile(client, whitelistXrayConfigPath, []byte(config), "0644"); err != nil {
		return err
	}
	if _, err := runRemote(client, "systemctl restart whitelist-xray.service && systemctl is-active whitelist-xray.service"); err != nil {
		return err
	}
	return nil
}

func nextGuestAddress(owner inviteProfile, guests []inviteProfile) (string, error) {
	used := map[int]bool{}
	ownerOctet, err := addressLastOctet(owner.WireGuard.Address)
	if err == nil {
		used[ownerOctet] = true
	}
	for _, guest := range guests {
		octet, err := addressLastOctet(guest.WireGuard.Address)
		if err == nil {
			used[octet] = true
		}
	}

	for octet := 3; octet <= 254; octet++ {
		if !used[octet] {
			return fmt.Sprintf("10.66.66.%d/32", octet), nil
		}
	}
	return "", fmt.Errorf("no free guest addresses left in 10.66.66.0/24")
}

func addressLastOctet(address string) (int, error) {
	base := strings.TrimSuffix(strings.TrimSpace(address), "/32")
	parts := strings.Split(base, ".")
	if len(parts) != 4 {
		return 0, fmt.Errorf("invalid address %q", address)
	}
	return strconv.Atoi(parts[3])
}

func nextGuestID(guests []inviteProfile) string {
	maxID := 0
	for _, guest := range guests {
		if strings.HasPrefix(guest.ID, "guest-") {
			value, err := strconv.Atoi(strings.TrimPrefix(guest.ID, "guest-"))
			if err == nil && value > maxID {
				maxID = value
			}
		}
	}
	return fmt.Sprintf("guest-%03d", maxID+1)
}

func effectiveRealityPort(owner inviteProfile, xrayState remoteXrayState) int {
	if xrayState.Reality.Port > 0 {
		return xrayState.Reality.Port
	}
	if owner.VLESSReality.Port > 0 {
		return owner.VLESSReality.Port
	}
	if reality, err := readInviteRealityFallback(owner); err == nil {
		return reality.Port
	}
	return 0
}

func enrichInviteProfile(invite *inviteProfile, owner inviteProfile, xrayState remoteXrayState) {
	invite.Protocol = normalizedInviteProtocol(*invite)
	if invite.Status == "" {
		invite.Status = "active"
	}
	if invite.Transport == "" {
		invite.Transport = owner.Transport
	}
	if invite.ServerHost == "" {
		invite.ServerHost = owner.ServerHost
	}
	if invite.VKTurnProxyPort == 0 {
		invite.VKTurnProxyPort = owner.VKTurnProxyPort
	}
	if invite.Protocol == string(ProtocolVLESSReality) {
		if reality, err := readInviteRealityFallback(owner); err == nil {
			if invite.VLESSReality.Port == 0 {
				invite.VLESSReality.Port = effectiveRealityPort(owner, xrayState)
			}
			if invite.VLESSReality.ServerName == "" {
				if xrayState.Reality.ServerName != "" {
					invite.VLESSReality.ServerName = xrayState.Reality.ServerName
				} else {
					invite.VLESSReality.ServerName = reality.ServerName
				}
			}
			if invite.VLESSReality.PublicKey == "" {
				invite.VLESSReality.PublicKey = reality.PublicKey
			}
			if invite.VLESSReality.ShortID == "" {
				if xrayState.Reality.ShortID != "" {
					invite.VLESSReality.ShortID = xrayState.Reality.ShortID
				} else {
					invite.VLESSReality.ShortID = reality.ShortID
				}
			}
			if invite.VLESSReality.UUID == "" {
				invite.VLESSReality.UUID = reality.UUID
			}
			if invite.VLESSReality.Flow == "" {
				invite.VLESSReality.Flow = reality.Flow
			}
		}
	}
	if invite.EndpointPort == 0 {
		if invite.Protocol == string(ProtocolVLESSReality) {
			invite.EndpointPort = effectiveRealityPort(owner, xrayState)
		} else {
			invite.EndpointPort = effectiveInviteEndpointPort(owner)
		}
	}
	if invite.Endpoint == "" {
		invite.Endpoint = fmt.Sprintf("%s:%d", invite.ServerHost, effectiveInviteEndpointPort(*invite))
	}
	if invite.Fingerprint == "" {
		invite.Fingerprint = inviteFingerprint(invite.ServerHost, effectiveInviteEndpointPort(*invite), inviteIdentityValue(*invite))
	}
	if invite.WireGuard.ServerPublicKey == "" {
		invite.WireGuard.ServerPublicKey = owner.WireGuard.ServerPublicKey
	}
	if invite.WireGuard.MTU == 0 {
		invite.WireGuard.MTU = owner.WireGuard.MTU
	}
}

func remoteGuestProfilePath(guestID string) string {
	return whitelistGuestProfilesDir + "/" + sanitizeHost(guestID) + ".json"
}

func nowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339)
}

func effectiveInviteEndpointPort(invite inviteProfile) int {
	if invite.EndpointPort > 0 {
		return invite.EndpointPort
	}
	if normalizedInviteProtocol(invite) == string(ProtocolVLESSReality) && invite.VLESSReality.Port > 0 {
		return invite.VLESSReality.Port
	}
	return invite.VKTurnProxyPort
}
