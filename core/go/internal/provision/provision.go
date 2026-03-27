package provision

type AuthMethod string
type Transport string
type StepStatus string

const (
	AuthPassword   AuthMethod = "password"
	AuthPrivateKey AuthMethod = "private-key"

	TransportVKTurnProxyXray Transport = "vk-turn-proxy+xray"
	TransportXray            Transport = "xray"

	StatusQueued StepStatus = "queued"
)

type Server struct {
	Host       string     `json:"host"`
	Port       int        `json:"port"`
	Username   string     `json:"username"`
	AuthMethod AuthMethod `json:"authMethod"`
	Transport  Transport  `json:"transport"`
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
	ServerHost string   `json:"serverHost"`
	Transport  string   `json:"transport"`
	Steps      []Step   `json:"steps"`
	Warnings   []string `json:"warnings"`
}
