// Local-only end-to-end verification for the actual frpclib wrapper.
// Run from go/: FRPS_BIN=/path/frps go run ./e2e
// All listeners bind 127.0.0.1 on unused ephemeral ports. Only test processes
// started by this harness are stopped; deferred cleanup runs on every failure.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"frpclient/frpclib"
	"github.com/fatedier/frp/client"
	"github.com/fatedier/frp/pkg/config"
	"github.com/fatedier/frp/pkg/config/source"
	v1 "github.com/fatedier/frp/pkg/config/v1"
	"github.com/fatedier/frp/pkg/policy/security"
)

const stubTags = `{"models":[{"name":"e2e-stub:tiny","model":"e2e-stub:tiny"}]}`

type process struct {
	cmd  *exec.Cmd
	done chan error
}

func startProcess(bin, config string) (*process, error) {
	cmd := exec.Command(bin, "-c", config)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	p := &process{cmd: cmd, done: make(chan error, 1)}
	go func() { p.done <- cmd.Wait() }()
	return p, nil
}

func (p *process) close() {
	select {
	case <-p.done:
		return
	default:
	}
	_ = p.cmd.Process.Signal(os.Interrupt)
	select {
	case <-p.done:
	case <-time.After(2 * time.Second):
		_ = p.cmd.Process.Kill()
		<-p.done
	}
	fmt.Println("PASS: owned frps process exited and was reaped")
}

func binPath(env, name string) (string, error) {
	if p := os.Getenv(env); p != "" {
		return p, nil
	}
	return exec.LookPath(name)
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func writeConfig(dir, name, content string) (string, error) {
	p := filepath.Join(dir, name)
	return p, os.WriteFile(p, []byte(content), 0600)
}

func waitUntil(timeout time.Duration, fn func() bool) bool {
	deadline := time.Now().Add(timeout)
	for {
		if fn() {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func tempConfigs() map[string]bool {
	files, _ := filepath.Glob(filepath.Join(os.TempDir(), "frpclient-*.toml"))
	out := make(map[string]bool)
	for _, file := range files {
		out[file] = true
	}
	return out
}

func makeTLSFiles(dir string) (caPath, certPath, keyPath, wrongCAPath string, err error) {
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", "", "", "", err
	}
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "FrpClient E2E CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		return "", "", "", "", err
	}
	caPath, err = writeConfig(dir, "ca.pem", string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})))
	if err != nil {
		return "", "", "", "", err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", "", "", "", err
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "localhost"},
		DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	certDER, err := x509.CreateCertificate(rand.Reader, cert, ca, &key.PublicKey, caKey)
	if err != nil {
		return "", "", "", "", err
	}
	certPath, err = writeConfig(dir, "server.pem", string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})))
	if err != nil {
		return "", "", "", "", err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return "", "", "", "", err
	}
	keyPath, err = writeConfig(dir, "server-key.pem", string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})))
	if err != nil {
		return "", "", "", "", err
	}
	wrongKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", "", "", "", err
	}
	wrongDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &wrongKey.PublicKey, wrongKey)
	if err != nil {
		return "", "", "", "", err
	}
	wrongCAPath, err = writeConfig(dir, "wrong-ca.pem", string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: wrongDER})))
	return
}

func startPublisher(text string) (func(), error) {
	var raw v1.ClientConfig
	if err := config.LoadConfigure([]byte(text), &raw, true, "toml"); err != nil {
		return nil, err
	}
	if err := raw.ClientCommonConfig.Complete(); err != nil {
		return nil, err
	}
	var proxies []v1.ProxyConfigurer
	for _, proxy := range raw.Proxies {
		proxies = append(proxies, proxy.ProxyConfigurer)
	}
	proxies = config.CompleteProxyConfigurers(proxies)
	sourceConfig := source.NewConfigSource()
	if err := sourceConfig.ReplaceAll(proxies, nil); err != nil {
		return nil, err
	}
	svc, err := client.NewService(client.ServiceOptions{Common: &raw.ClientCommonConfig,
		ConfigSourceAggregator: source.NewAggregator(sourceConfig), UnsafeFeatures: security.NewUnsafeFeatures(nil)})
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { defer close(done); _ = svc.Run(ctx) }()
	return func() {
		cancel()
		svc.GracefulClose(0)
		select {
		case <-done:
			fmt.Println("PASS: owned publisher service exited")
		case <-time.After(3 * time.Second):
			fmt.Println("WARNING: owned publisher cleanup timed out")
		}
	}, nil
}

func run() error {
	// The harness is strictly local, independent of a shell's proxy settings.
	_ = os.Unsetenv("http_proxy")
	_ = os.Unsetenv("HTTP_PROXY")
	_ = os.Unsetenv("https_proxy")
	_ = os.Unsetenv("HTTPS_PROXY")
	frpsBin, err := binPath("FRPS_BIN", "frps")
	if err != nil {
		return fmt.Errorf("frps binary: %w", err)
	}
	for name, path := range map[string]string{"frps": frpsBin} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		output, versionErr := exec.CommandContext(ctx, path, "--version").Output()
		cancel()
		if versionErr != nil || strings.TrimSpace(string(output)) != frpclib.Version() {
			return fmt.Errorf("%s version does not match wrapper %s", name, frpclib.Version())
		}
	}
	dir, err := os.MkdirTemp("", "frp-e2e-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	before := tempConfigs()
	caPath, certPath, keyPath, wrongCAPath, err := makeTLSFiles(dir)
	if err != nil {
		return fmt.Errorf("local test certificates: %w", err)
	}

	stubListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	stubPort := stubListener.Addr().(*net.TCPAddr).Port
	mux := http.NewServeMux()
	mux.HandleFunc("/api/tags", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, stubTags)
	})
	stubServer := &http.Server{Handler: mux}
	go func() { _ = stubServer.Serve(stubListener) }()
	defer stubServer.Close()
	serverPort, err := freePort()
	if err != nil {
		return err
	}
	visitorPort, err := freePort()
	if err != nil {
		return err
	}
	if visitorPort == serverPort {
		return errors.New("ephemeral test ports collided; rerun the harness")
	}
	if visitorPort == 11434 {
		return errors.New("ephemeral visitor port unexpectedly equals production default")
	}

	serverConfig, err := writeConfig(dir, "frps.toml", fmt.Sprintf(`bindAddr = "127.0.0.1"
bindPort = %d
auth.method = "token"
auth.token = "e2e-token-only"
log.level = "warn"
transport.tls.certFile = %q
transport.tls.keyFile = %q
`, serverPort, certPath, keyPath))
	if err != nil {
		return err
	}
	server, err := startProcess(frpsBin, serverConfig)
	if err != nil {
		return fmt.Errorf("start owned frps: %w", err)
	}
	defer server.close()
	serverAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(serverPort))
	if !waitUntil(5*time.Second, func() bool {
		conn, dialErr := net.DialTimeout("tcp", serverAddr, 100*time.Millisecond)
		if dialErr == nil {
			conn.Close()
			return true
		}
		return false
	}) {
		return errors.New("owned frps did not become ready")
	}

	publisherConfig := fmt.Sprintf(`serverAddr = "127.0.0.1"
serverPort = %d
auth.method = "token"
auth.token = "e2e-token-only"
log.level = "warn"
[[proxies]]
name = "e2e-model"
type = "stcp"
secretKey = "e2e-secret-only"
localIP = "127.0.0.1"
localPort = %d
`, serverPort, stubPort)
	closePublisher, err := startPublisher(publisherConfig)
	if err != nil {
		return fmt.Errorf("start owned publisher: %w", err)
	}
	defer closePublisher()

	visitor := fmt.Sprintf(`serverAddr = "127.0.0.1"
serverPort = %d
auth.method = "token"
auth.token = "e2e-token-only"
transport.tls.trustedCaFile = %q
transport.tls.serverName = "localhost"
[[visitors]]
name = "e2e-ios"
type = "stcp"
serverName = "e2e-model"
secretKey = "e2e-secret-only"
bindAddr = "127.0.0.1"
bindPort = %d
`, serverPort, caPath, visitorPort)
	if err = frpclib.Start(visitor); err != nil {
		return fmt.Errorf("wrapper start: %w", err)
	}
	defer frpclib.Stop()
	client := &http.Client{Timeout: time.Second}
	visitorAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(visitorPort))
	endpoint := "http://" + visitorAddr + "/api/tags"
	if !waitUntil(10*time.Second, func() bool {
		response, requestErr := client.Get(endpoint)
		if requestErr != nil {
			return false
		}
		defer response.Body.Close()
		body, _ := io.ReadAll(response.Body)
		return response.StatusCode == 200 && string(body) == stubTags
	}) {
		return fmt.Errorf("tunnel did not serve stub; running=%t error=%s", frpclib.IsRunning(), frpclib.LastError())
	}
	fmt.Printf("PASS: real STCP visitor served expected /api/tags on nondefault loopback port %d\n", visitorPort)
	if !frpclib.IsRunning() {
		return errors.New("wrapper lost running service after successful probe")
	}
	frpclib.Stop()
	if frpclib.IsRunning() || frpclib.IsStopping() {
		return errors.New("wrapper did not finish stop")
	}
	if !waitUntil(time.Second, func() bool {
		conn, dialErr := net.DialTimeout("tcp", visitorAddr, 100*time.Millisecond)
		if dialErr == nil {
			conn.Close()
			return false
		}
		return true
	}) {
		return errors.New("visitor bind remained open after Stop")
	}
	fmt.Println("PASS: Stop completed and closed the visitor bind")

	wrongToken := strings.Replace(visitor, "e2e-token-only", "e2e-wrong-token-only", 1)
	if err = frpclib.Start(wrongToken); err != nil {
		return fmt.Errorf("wrong-token start: %w", err)
	}
	if !waitUntil(5*time.Second, func() bool { return !frpclib.IsRunning() }) {
		return errors.New("wrong-token first login did not terminate")
	}
	if !strings.Contains(frpclib.LastError(), "token") {
		return errors.New("wrong-token failure did not surface terminal auth error")
	}
	fmt.Println("PASS: wrong-token first login terminated with an authentication error")
	for label, invalid := range map[string]string{
		"wrong certificate authority": strings.Replace(visitor, caPath, wrongCAPath, 1),
		"wrong server identity":       strings.Replace(visitor, `transport.tls.serverName = "localhost"`, `transport.tls.serverName = "wrong.invalid"`, 1),
	} {
		if err = frpclib.Start(invalid); err != nil {
			return fmt.Errorf("%s start: %w", label, err)
		}
		if !waitUntil(5*time.Second, func() bool { return !frpclib.IsRunning() }) {
			return fmt.Errorf("%s did not terminate", label)
		}
		if !strings.Contains(frpclib.LastError(), "x509") {
			return fmt.Errorf("%s did not surface certificate rejection", label)
		}
		fmt.Println("PASS:", label, "was rejected and the first login terminated")
	}
	for file := range tempConfigs() {
		if !before[file] {
			return errors.New("wrapper created a new plaintext temporary config")
		}
	}
	fmt.Println("PASS: wrapper created no frpclient-*.toml temporary configuration")
	fmt.Println("E2E PASS: local-only STCP, model endpoint, stop cleanup, auth/TLS rejection, in-memory config")
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "E2E FAIL:", err)
		os.Exit(1)
	}
}
