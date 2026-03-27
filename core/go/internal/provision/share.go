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
	ShareCode       string `json:"shareCode"`
	RawJSON         string `json:"rawJson"`
	LocalPath       string `json:"localPath,omitempty"`
	ImportedAt      string `json:"importedAt,omitempty"`
	CreatedAt       string `json:"createdAt,omitempty"`
	RevokedAt       string `json:"revokedAt,omitempty"`
	Status          string `json:"status,omitempty"`
	Error           string `json:"error,omitempty"`
}

func GenerateGuestInvite(host, name string) InviteProfileResponse {
	profileResp := GetLocalOwnerProfile(host)
	if profileResp.Error != "" {
		return InviteProfileResponse{Error: profileResp.Error}
	}
	if !profileResp.Exists {
		return InviteProfileResponse{Error: "owner profile not found for host"}
	}

	endpointPort := profileResp.EndpointPort
	if endpointPort == 0 {
		endpointPort = profileResp.VKTurnProxyPort
	}
	invite := inviteProfile{
		Role:            "guest",
		Name:            defaultInviteName(name),
		Protocol:        "wireguard",
		Transport:       profileResp.Transport,
		ServerHost:      profileResp.ServerHost,
		VKTurnProxyPort: profileResp.VKTurnProxyPort,
		EndpointPort:    endpointPort,
		Endpoint:        fmt.Sprintf("%s:%d", profileResp.ServerHost, endpointPort),
		Fingerprint:     inviteFingerprint(profileResp.ServerHost, endpointPort, profileResp.WireGuard.ServerPublicKey),
	}
	invite.WireGuard.ServerPublicKey = profileResp.WireGuard.ServerPublicKey
	invite.WireGuard.ClientPrivateKey = profileResp.WireGuard.ClientPrivateKey
	invite.WireGuard.ClientPublicKey = profileResp.WireGuard.ClientPublicKey
	invite.WireGuard.Address = profileResp.WireGuard.Address
	invite.WireGuard.MTU = profileResp.WireGuard.MTU

	return buildInviteResponse(invite, "")
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
	if err := validateInvite(invite); err != nil {
		return invite, "", err
	}

	normalized, err := json.MarshalIndent(invite, "", "  ")
	if err != nil {
		return invite, "", fmt.Errorf("normalize invite profile: %w", err)
	}
	return invite, string(normalized), nil
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
	if strings.TrimSpace(invite.WireGuard.ServerPublicKey) == "" || strings.TrimSpace(invite.WireGuard.ClientPrivateKey) == "" {
		return fmt.Errorf("invite profile wireguard keys are required")
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

	guestKeys, err := generateWireGuardKeyPair()
	if err != nil {
		return InviteProfileResponse{}, err
	}

	nextAddress, err := nextGuestAddress(owner, guestProfiles)
	if err != nil {
		return InviteProfileResponse{}, err
	}

	guestID := nextGuestID(guestProfiles)
	guest := inviteProfile{
		ID:              guestID,
		Role:            "guest",
		Name:            defaultInviteName(name),
		Protocol:        "wireguard",
		Transport:       owner.Transport,
		ServerHost:      owner.ServerHost,
		VKTurnProxyPort: owner.VKTurnProxyPort,
		EndpointPort:    effectiveInviteEndpointPort(owner),
		Endpoint:        fmt.Sprintf("%s:%d", owner.ServerHost, effectiveInviteEndpointPort(owner)),
		CreatedAt:       nowRFC3339(),
		Status:          "active",
	}
	guest.WireGuard.ServerPublicKey = owner.WireGuard.ServerPublicKey
	guest.WireGuard.ClientPrivateKey = guestKeys.Private
	guest.WireGuard.ClientPublicKey = guestKeys.Public
	guest.WireGuard.Address = nextAddress
	guest.WireGuard.MTU = owner.WireGuard.MTU
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

type remoteXrayState struct {
	WireGuardPort int
	SecretKey     string
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

	xrayText, err := runRemote(client, "cat "+quoteShell(whitelistXrayConfigPath))
	if err != nil {
		return owner, ownerText, xrayState, err
	}

	var parsed struct {
		Inbounds []struct {
			Port     int `json:"port"`
			Settings struct {
				SecretKey string `json:"secretKey"`
			} `json:"settings"`
		} `json:"inbounds"`
	}
	if err := json.Unmarshal([]byte(xrayText), &parsed); err != nil {
		return owner, ownerText, xrayState, fmt.Errorf("parse remote xray config: %w", err)
	}
	if len(parsed.Inbounds) == 0 {
		return owner, ownerText, xrayState, fmt.Errorf("remote xray config has no inbounds")
	}

	xrayState.WireGuardPort = parsed.Inbounds[0].Port
	xrayState.SecretKey = parsed.Inbounds[0].Settings.SecretKey
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

	for _, guest := range guests {
		if guest.Status == "revoked" || guest.RevokedAt != "" {
			continue
		}
		peers = append(peers, xrayWireGuardPeer{
			PublicKey:  guest.WireGuard.ClientPublicKey,
			AllowedIPs: []string{guest.WireGuard.Address},
		})
	}

	listenHost := "127.0.0.1"
	if owner.Transport == string(TransportXray) {
		listenHost = "0.0.0.0"
	}
	config := renderXrayConfigWithListen(xrayState.SecretKey, peers, listenHost, xrayState.WireGuardPort)
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

func enrichInviteProfile(invite *inviteProfile, owner inviteProfile, xrayState remoteXrayState) {
	if invite.Protocol == "" {
		invite.Protocol = "wireguard"
	}
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
	if invite.EndpointPort == 0 {
		invite.EndpointPort = effectiveInviteEndpointPort(owner)
	}
	if invite.Endpoint == "" {
		invite.Endpoint = fmt.Sprintf("%s:%d", invite.ServerHost, effectiveInviteEndpointPort(*invite))
	}
	if invite.Fingerprint == "" {
		invite.Fingerprint = inviteFingerprint(invite.ServerHost, effectiveInviteEndpointPort(*invite), invite.WireGuard.ClientPublicKey)
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
	return invite.VKTurnProxyPort
}
