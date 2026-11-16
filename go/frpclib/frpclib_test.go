package frpclib

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const sampleTOML = `serverAddr = "example.invalid"
serverPort = 7000
auth.method = "token"
auth.token = "test-token-long-value"
[[visitors]]
name = "ollama-visitor-ios"
type = "stcp"
serverName = "ollama"
secretKey = "test-secret-long-value"
bindAddr = "127.0.0.1"
bindPort = 11434
`

func TestVersion(t *testing.T) {
	if Version() != "0.72.0" {
		t.Fatal(Version())
	}
}
func TestConfigValidation(t *testing.T) {
	cases := []struct {
		name, text string
		valid      bool
	}{
		{"valid", sampleTOML, true},
		{"invalid TOML", "this is not [valid toml", false},
		{"unknown field", sampleTOML + "\nbogusField = 1\n", false},
		{"bad visitor", strings.Replace(sampleTOML, `type = "stcp"`, `type = "nope"`, 1), false},
		{"nonloopback", strings.Replace(sampleTOML, `bindAddr = "127.0.0.1"`, `bindAddr = "0.0.0.0"`, 1), false},
		{"bad port", strings.Replace(sampleTOML, "bindPort = 11434", "bindPort = -1", 1), false},
		{"empty", "  \n", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := ConfigInfo(c.text)
			if (err == nil) != c.valid {
				t.Fatalf("valid=%v err=%v", c.valid, err)
			}
		})
	}
}
func TestConfigInfoActualEndpointAndAdvancedPreservation(t *testing.T) {
	p := decodeInfo(t, strings.Replace(sampleTOML, "bindPort = 11434", "bindPort = 12345", 1))
	if p.TestURL != "http://127.0.0.1:12345/api/tags" || p.CustomConfig || p.TLSVerified {
		t.Fatalf("unexpected endpoint/profile: %+v", p)
	}
	custom := "transport.tcpMux = false\n" + sampleTOML
	p = decodeInfo(t, custom)
	if !p.CustomConfig {
		t.Fatal("advanced field would be silently lost")
	}
	data, _ := json.Marshal(p)
	if _, err := BuildVisitorConfig(string(data)); err == nil {
		t.Fatal("custom config replaced implicitly")
	}
}
func TestBuildVisitorRoundtripEscapesAndTLS(t *testing.T) {
	p := visitorProfile{ServerAddr: "example.invalid", Token: "quoted\"token\\value", SecretKey: "secret\nline", ServerPort: 7001, BindAddr: "::1", BindPort: 11435, UseSystemCA: true, ServerUser: "owner", ServerName: "model", VisitorName: "phone"}
	data, _ := json.Marshal(p)
	text, err := BuildVisitorConfig(string(data))
	if err != nil {
		t.Fatal(err)
	}
	got := decodeInfo(t, text)
	if got.Token != p.Token || got.SecretKey != p.SecretKey || !got.TLSVerified || !got.CustomConfig || got.TestURL != "http://[::1]:11435/api/tags" || got.ServerUser != "owner" {
		t.Fatalf("roundtrip mismatch: %+v", got)
	}
	if _, err := newService(text); err != nil {
		t.Fatal(err)
	}
}
func TestParserErrorsNeverEchoInput(t *testing.T) {
	bad := "auth.token = \"very-private-token\"\nauth.secret = \"very-private-secret\"\n"
	_, err := ConfigInfo(bad)
	if err == nil || strings.Contains(err.Error(), "very-private") {
		t.Fatalf("unsafe parser error: %v", err)
	}
}
func decodeInfo(t *testing.T, text string) visitorProfile {
	t.Helper()
	s, err := ConfigInfo(text)
	if err != nil {
		t.Fatal(err)
	}
	var p visitorProfile
	if err := json.Unmarshal([]byte(s), &p); err != nil {
		t.Fatal(err)
	}
	return p
}

type fakeRunner struct {
	entered      chan struct{}
	release      chan struct{}
	ignoreCancel bool
	err          error
	closeCount   atomic.Int32
}

func (f *fakeRunner) Run(ctx context.Context) error {
	close(f.entered)
	if f.ignoreCancel {
		<-f.release
	} else {
		select {
		case <-ctx.Done():
		case <-f.release:
		}
	}
	return f.err
}
func (f *fakeRunner) GracefulClose(time.Duration) { f.closeCount.Add(1) }
func fakeService() *fakeRunner {
	return &fakeRunner{entered: make(chan struct{}), release: make(chan struct{})}
}
func useFactory(t *testing.T, f func(string) (serviceRunner, error)) {
	t.Helper()
	if IsRunning() {
		t.Fatal("previous test left a service alive")
	}
	lifecycleMu.Lock()
	old := serviceFactory
	serviceFactory = f
	lifecycleMu.Unlock()
	t.Cleanup(func() { Stop(); lifecycleMu.Lock(); serviceFactory = old; lifecycleMu.Unlock() })
}
func await(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(time.Second):
		t.Fatal("timed out")
	}
}
func awaitIdle(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for IsRunning() {
		if time.Now().After(deadline) {
			t.Fatal("still running")
		}
		time.Sleep(time.Millisecond)
	}
}
func TestConcurrentStartOwnsExactlyOneService(t *testing.T) {
	fake := fakeService()
	var count atomic.Int32
	buildEntered, buildRelease := make(chan struct{}), make(chan struct{})
	useFactory(t, func(string) (serviceRunner, error) {
		if count.Add(1) == 1 {
			close(buildEntered)
			<-buildRelease
		}
		return fake, nil
	})
	var wg sync.WaitGroup
	results := make(chan error, 10)
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); results <- Start(sampleTOML) }()
	}
	await(t, buildEntered)
	close(buildRelease)
	wg.Wait()
	close(results)
	success := 0
	for err := range results {
		if err == nil {
			success++
		}
	}
	if success != 1 || count.Load() != 1 {
		t.Fatalf("success=%d constructions=%d", success, count.Load())
	}
	await(t, fake.entered)
	Stop()
	awaitIdle(t)
}
func TestStopTimeoutKeepsOwnership(t *testing.T) {
	fake := fakeService()
	fake.ignoreCancel = true
	useFactory(t, func(string) (serviceRunner, error) { return fake, nil })
	oldTimeout := stopTimeout
	stopTimeout = 20 * time.Millisecond
	t.Cleanup(func() { stopTimeout = oldTimeout })
	if err := Start(sampleTOML); err != nil {
		t.Fatal(err)
	}
	await(t, fake.entered)
	Stop()
	if !IsRunning() || !IsStopping() {
		t.Fatal("timed-out service lost ownership")
	}
	if err := Start(sampleTOML); err == nil {
		t.Fatal("started over live timed-out service")
	}
	close(fake.release)
	awaitIdle(t)
	if IsStopping() {
		t.Fatal("stopping state not cleared after real exit")
	}
}
func TestAsyncExitAndRestart(t *testing.T) {
	fake := fakeService()
	fake.err = errors.New("failed auth for test-token-long-value / test-secret-long-value")
	useFactory(t, func(string) (serviceRunner, error) { return fake, nil })
	if err := Start(sampleTOML); err != nil {
		t.Fatal(err)
	}
	await(t, fake.entered)
	close(fake.release)
	awaitIdle(t)
	err := LastError()
	if !strings.Contains(err, "[REDACTED]") || strings.Contains(err, "test-token-long-value") || strings.Contains(err, "test-secret-long-value") {
		t.Fatal("unredacted runtime error")
	}
	fake = fakeService()
	if err := Start(sampleTOML); err != nil {
		t.Fatal(err)
	}
	await(t, fake.entered)
	Stop()
	awaitIdle(t)
}
func TestStartEmptyConfigAndIdleStop(t *testing.T) {
	if Start(" \n") == nil {
		t.Fatal("empty config accepted")
	}
	Stop()
	if IsRunning() {
		t.Fatal("idle stop running")
	}
}

func TestStopQueuedDuringConstructionOwnsResult(t *testing.T) {
	fake := fakeService()
	buildEntered, buildRelease := make(chan struct{}), make(chan struct{})
	useFactory(t, func(string) (serviceRunner, error) { close(buildEntered); <-buildRelease; return fake, nil })
	startDone := make(chan struct{})
	go func() {
		defer close(startDone)
		if err := Start(sampleTOML); err != nil {
			t.Error(err)
		}
	}()
	await(t, buildEntered)
	stopDone := make(chan struct{})
	go func() { Stop(); close(stopDone) }()
	close(buildRelease)
	await(t, startDone)
	await(t, stopDone)
	if IsRunning() || IsStopping() {
		t.Fatal("stop lost service constructed concurrently")
	}
}

func TestConstructionFailureReleasesReservation(t *testing.T) {
	fake := fakeService()
	count := 0
	useFactory(t, func(string) (serviceRunner, error) {
		count++
		if count == 1 {
			return nil, errors.New("test construction failure")
		}
		return fake, nil
	})
	if Start(sampleTOML) == nil {
		t.Fatal("construction failure lost")
	}
	if IsRunning() || IsStopping() {
		t.Fatal("failed construction left occupied state")
	}
	if err := Start(sampleTOML); err != nil {
		t.Fatal(err)
	}
	await(t, fake.entered)
	Stop()
	awaitIdle(t)
}

type recordingListener struct {
	mu   sync.Mutex
	text string
}

func (l *recordingListener) Log(msg string) { l.mu.Lock(); l.text += msg; l.mu.Unlock() }
func TestLogAndReturnedErrorRedactKnownSecrets(t *testing.T) {
	rememberSecrets(sampleTOML)
	l := &recordingListener{}
	SetLogListener(l)
	defer SetLogListener(nil)
	raw := "test-token-long-value and test-secret-long-value"
	_, _ = (callbackWriter{}).Write([]byte(raw))
	l.mu.Lock()
	got := l.text
	l.mu.Unlock()
	if strings.Contains(got, "test-token-long-value") || strings.Contains(got, "test-secret-long-value") || strings.Count(got, "[REDACTED]") != 2 {
		t.Fatal("log not redacted")
	}
	err := safeError(errors.New(raw))
	if strings.Contains(err.Error(), "test-token-long-value") || strings.Count(err.Error(), "[REDACTED]") != 2 {
		t.Fatal("returned error not redacted")
	}
}

func TestAppOwnsLoginRetriesAndPreservesAlternateLoopback(t *testing.T) {
	if _, err := ConfigInfo("loginFailExit = false\n" + sampleTOML); err == nil {
		t.Fatal("unbounded internal first-login retries accepted")
	}
	text := strings.Replace(sampleTOML, `bindAddr = "127.0.0.1"`, `bindAddr = "::1"`, 1)
	info, err := ConfigInfo(text)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(info, `"customConfig":true`) || !strings.Contains(info, `[::1]`) {
		t.Fatal("alternate loopback would be silently overwritten by the basic form")
	}
}
