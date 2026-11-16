package frpclib

import (
	"encoding/json"
	"errors"
	"github.com/fatedier/frp/pkg/config"
	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/config/v1/validation"
	"github.com/fatedier/frp/pkg/policy/security"
	toml "github.com/pelletier/go-toml/v2"
	"net"
	"strconv"
	"strings"
)

type loadedConfig struct {
	common   *v1.ClientCommonConfig
	proxies  []v1.ProxyConfigurer
	visitors []v1.VisitorConfigurer
}

// JSON keeps the gomobile boundary small; it is never written to a log.
type visitorProfile struct {
	ServerAddr    string `json:"serverAddr"`
	ServerPort    int    `json:"serverPort"`
	Token         string `json:"token"`
	SecretKey     string `json:"secretKey"`
	VisitorName   string `json:"visitorName"`
	ServerName    string `json:"serverName"`
	BindAddr      string `json:"bindAddr"`
	BindPort      int    `json:"bindPort"`
	TestURL       string `json:"testURL"`
	TLSVerified   bool   `json:"tlsVerified"`
	UseSystemCA   bool   `json:"useSystemCA"`
	TrustedCaFile string `json:"trustedCaFile"`
	ServerUser    string `json:"serverUser"`
	CustomConfig  bool   `json:"customConfig"`
}

func loadConfig(text string) (*loadedConfig, error) {
	if len(text) > 131072 {
		return nil, errors.New("configuration exceeds 128 KB")
	}
	if strings.TrimSpace(text) == "" {
		return nil, errors.New("empty config")
	}
	var raw v1.ClientConfig
	// Literal TOML, not templates or implicit reads of external includes.
	if err := config.LoadConfigure([]byte(text), &raw, true, "toml"); err != nil {
		return nil, errors.New("invalid TOML or unsupported configuration field")
	}
	if len(raw.IncludeConfigFiles) > 0 {
		return nil, errors.New("external config includes are not supported")
	}
	if raw.LoginFailExit != nil && !*raw.LoginFailExit {
		return nil, errors.New("loginFailExit must be true: the app manages bounded login retries")
	}
	if err := raw.ClientCommonConfig.Complete(); err != nil {
		return nil, errors.New("invalid authentication configuration")
	}
	out := &loadedConfig{common: &raw.ClientCommonConfig}
	for _, p := range raw.Proxies {
		out.proxies = append(out.proxies, p.ProxyConfigurer)
	}
	for _, v := range raw.Visitors {
		out.visitors = append(out.visitors, v.VisitorConfigurer)
	}
	out.proxies, out.visitors = config.FilterClientConfigurers(out.common, out.proxies, out.visitors)
	out.proxies = config.CompleteProxyConfigurers(out.proxies)
	out.visitors = config.CompleteVisitorConfigurers(out.visitors)
	if _, err := validation.ValidateAllClientConfig(out.common, out.proxies, out.visitors, security.NewUnsafeFeatures(nil)); err != nil {
		return nil, errors.New("invalid client configuration (check server, visitor and port settings)")
	}
	return out, nil
}

// ConfigInfo validates literal TOML and describes the single active STCP
// visitor tested by this app. It never opens a network connection.
func ConfigInfo(configTOML string) (string, error) {
	loaded, err := loadConfig(configTOML)
	if err != nil {
		return "", err
	}
	if len(loaded.visitors) != 1 {
		return "", errors.New("configure exactly one active STCP visitor")
	}
	v := loaded.visitors[0].GetBaseConfig()
	if v.Type != "stcp" {
		return "", errors.New("the model connection requires a STCP visitor")
	}
	if loaded.common.Auth.Method != v1.AuthMethodToken || loaded.common.Auth.TokenSource != nil {
		return "", errors.New("this profile requires inline token authentication")
	}
	host, err := loopbackHost(v.BindAddr, v.BindPort)
	if err != nil {
		return "", err
	}
	p := visitorProfile{
		ServerAddr: loaded.common.ServerAddr, ServerPort: loaded.common.ServerPort,
		Token: loaded.common.Auth.Token, SecretKey: v.SecretKey,
		VisitorName: v.Name, ServerName: v.ServerName, BindAddr: v.BindAddr, BindPort: v.BindPort,
		TestURL:       "http://" + net.JoinHostPort(host, strconv.Itoa(v.BindPort)) + "/api/tags",
		TLSVerified:   loaded.common.Transport.TLS.Enable != nil && *loaded.common.Transport.TLS.Enable && (loaded.common.Transport.TLS.UseSystemCa || loaded.common.Transport.TLS.TrustedCaFile != ""),
		UseSystemCA:   loaded.common.Transport.TLS.UseSystemCa,
		TrustedCaFile: loaded.common.Transport.TLS.TrustedCaFile, ServerUser: v.ServerUser,
		CustomConfig: isCustomConfig(configTOML),
	}
	data, err := json.Marshal(p)
	return string(data), err
}

func loopbackHost(host string, port int) (string, error) {
	if port < 1 || port > 65535 {
		return "", errors.New("visitor bind port must be between 1 and 65535")
	}
	if host == "localhost" {
		return "127.0.0.1", nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return "", errors.New("visitor bind address must be a loopback address")
	}
	return host, nil
}

// BuildVisitorConfig generates a basic single-STCP profile. Custom TOML is
// never replaced implicitly: callers must explicitly choose a basic profile.
func BuildVisitorConfig(profileJSON string) (string, error) {
	var p visitorProfile
	if json.Unmarshal([]byte(profileJSON), &p) != nil {
		return "", errors.New("invalid profile JSON")
	}
	if p.CustomConfig {
		return "", errors.New("custom TOML cannot be replaced by a basic form implicitly")
	}
	if p.ServerAddr == "" {
		p.ServerAddr = "example.invalid"
	}
	if p.ServerPort == 0 {
		p.ServerPort = 7000
	}
	if p.ServerPort < 1 || p.ServerPort > 65535 {
		return "", errors.New("server port must be between 1 and 65535")
	}
	if p.VisitorName == "" {
		p.VisitorName = "ollama-visitor-ios"
	}
	if p.ServerName == "" {
		p.ServerName = "ollama"
	}
	if p.BindAddr == "" {
		p.BindAddr = "127.0.0.1"
	}
	if p.BindPort == 0 {
		p.BindPort = 11434
	}
	if _, err := loopbackHost(p.BindAddr, p.BindPort); err != nil {
		return "", err
	}
	m := map[string]any{
		"serverAddr": p.ServerAddr, "serverPort": p.ServerPort,
		"auth":      map[string]any{"method": "token", "token": p.Token},
		"transport": map[string]any{"tls": map[string]any{"enable": true, "useSystemCa": p.UseSystemCA, "trustedCaFile": p.TrustedCaFile}},
		"visitors":  []map[string]any{{"name": p.VisitorName, "type": "stcp", "serverName": p.ServerName, "serverUser": p.ServerUser, "secretKey": p.SecretKey, "bindAddr": p.BindAddr, "bindPort": p.BindPort}},
	}
	data, err := toml.Marshal(m)
	if err != nil {
		return "", errors.New("could not generate TOML")
	}
	if _, err := ConfigInfo(string(data)); err != nil {
		return "", err
	}
	return string(data), nil
}

// Keep settings the basic editor cannot represent in the advanced editor.
func isCustomConfig(text string) bool {
	var raw map[string]any
	if toml.Unmarshal([]byte(text), &raw) != nil {
		return true
	}
	allowedRoot := map[string]bool{"serverAddr": true, "serverPort": true, "auth": true, "transport": true, "visitors": true}
	for k := range raw {
		if !allowedRoot[k] {
			return true
		}
	}
	auth, _ := raw["auth"].(map[string]any)
	for k := range auth {
		if k != "method" && k != "token" {
			return true
		}
	}
	tr, _ := raw["transport"].(map[string]any)
	for k := range tr {
		if k != "tls" {
			return true
		}
	}
	tls, _ := tr["tls"].(map[string]any)
	for k, v := range tls {
		if k != "enable" && k != "useSystemCa" && k != "trustedCaFile" {
			return true
		}
		if k == "enable" && v != true {
			return true
		}
	}
	visitors, ok := raw["visitors"].([]any)
	if !ok || len(visitors) != 1 {
		return true
	}
	allowed := map[string]bool{"name": true, "type": true, "serverName": true, "serverUser": true, "secretKey": true, "bindAddr": true, "bindPort": true}
	for _, v := range visitors {
		m, ok := v.(map[string]any)
		if !ok {
			return true
		}
		for k := range m {
			if !allowed[k] {
				return true
			}
		}
		if host, ok := m["bindAddr"].(string); ok && host != "" && host != "127.0.0.1" {
			return true
		}
	}
	return false
}

func secretValues(text string) []string {
	var root map[string]any
	if toml.Unmarshal([]byte(text), &root) != nil {
		return nil
	}
	var out []string
	var walk func(any)
	walk = func(v any) {
		switch x := v.(type) {
		case map[string]any:
			for k, item := range x {
				key := strings.ToLower(k)
				if key == "token" || key == "secretkey" || key == "password" || key == "clientsecret" {
					if s, ok := item.(string); ok && s != "" {
						out = append(out, s)
					}
				}
				walk(item)
			}
		case []any:
			for _, item := range x {
				walk(item)
			}
		}
	}
	walk(root)
	return out
}
