package provision

type AuthMethod string
type Transport string
type CoreEngine string
type TunnelProtocol string
type StepStatus string

const (
	AuthPassword   AuthMethod = "password"
	AuthPrivateKey AuthMethod = "private-key"

	TransportVKTurnProxyXray Transport = "vk-turn-proxy+xray"
	TransportXray            Transport = "xray"

	EngineXray    CoreEngine = "xray"
	EngineSingBox CoreEngine = "sing-box"

	ProtocolDirectWireGuard TunnelProtocol = "direct-wireguard"
	ProtocolVLESSReality    TunnelProtocol = "vless-reality"

	StatusQueued StepStatus = "queued"
)

type Server struct {
	Host       string         `json:"host"`
	Port       int            `json:"port"`
	Username   string         `json:"username"`
	AuthMethod AuthMethod     `json:"authMethod"`
	Transport  Transport      `json:"transport"`
	Engine     CoreEngine     `json:"engine,omitempty"`
	Protocol   TunnelProtocol `json:"protocol,omitempty"`
}

type Request struct {
	Server Server `json:"server"`
	Secret string `json:"secret"`
}

type Step struct {
	ID          string     `json:"id"`
	Label       string     `json:"label"`
	Status      StepStatus `json:"status"`
	Description string     `json:"description"`
}

type Response struct {
	ServerHost   string              `json:"serverHost"`
	Transport    string              `json:"transport"`
	Steps        []Step              `json:"steps"`
	Warnings     []string            `json:"warnings"`
	ProtocolPack []ProtocolPackEntry `json:"protocolPack,omitempty"`
}

func normalizedEngine(engine CoreEngine) CoreEngine {
	switch engine {
	case EngineSingBox:
		return engine
	default:
		return EngineXray
	}
}

func normalizedProtocol(transport Transport, protocol TunnelProtocol) TunnelProtocol {
	if transport == TransportVKTurnProxyXray {
		return ProtocolDirectWireGuard
	}
	switch protocol {
	case ProtocolVLESSReality:
		return protocol
	default:
		return ProtocolDirectWireGuard
	}
}
