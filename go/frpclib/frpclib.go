// Package frpclib runs the frp client in-process for the iOS app.
// Configuration is parsed in memory; no secret-bearing TOML is written to disk.
package frpclib

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/fatedier/frp/client"
	"github.com/fatedier/frp/pkg/config/source"
	"github.com/fatedier/frp/pkg/policy/security"
	frplog "github.com/fatedier/frp/pkg/util/log"
	"github.com/fatedier/frp/pkg/util/version"
	goliblog "github.com/fatedier/golib/log"
)

// LogListener receives redacted log lines on a Go goroutine.
type LogListener interface{ Log(msg string) }

type serviceRunner interface {
	Run(context.Context) error
	GracefulClose(time.Duration)
}

var (
	// lifecycleMu covers construction, publication and stop requests, whereas
	// mu is only held for short state snapshots. Run completion never needs
	// lifecycleMu, so Stop can wait for completion without deadlocking.
	lifecycleMu    sync.Mutex
	mu             sync.Mutex
	svc            serviceRunner
	cancel         context.CancelFunc
	done           chan struct{}
	running        bool
	stopping       bool
	closeInitiated bool
	lastErr        string
	listener       LogListener
	logOnce        sync.Once
	cleanupOnce    sync.Once
	redactions     []string
	serviceFactory = newService
	stopTimeout    = 5 * time.Second
)

type callbackWriter struct{}

func (callbackWriter) Write(p []byte) (int, error) {
	mu.Lock()
	l := listener
	text := redactLocked(strings.TrimRight(string(p), "\n"))
	mu.Unlock()
	// Redact before BOTH outputs. An unfiltered MultiWriter leaks to stdout.
	if text != "" {
		_, _ = os.Stdout.WriteString(text + "\n")
		if l != nil {
			l.Log(text)
		}
	}
	return len(p), nil
}

func installLogWriter() {
	logOnce.Do(func() {
		frplog.Logger = frplog.Logger.WithOptions(
			goliblog.WithOutput(callbackWriter{}),
			goliblog.WithLevel(goliblog.InfoLevel),
		)
	})
}

// SetLogListener registers a listener; nil stops callbacks.
func SetLogListener(l LogListener) {
	installLogWriter()
	mu.Lock()
	listener = l
	mu.Unlock()
}

// Version is the pinned frp version.
func Version() string { return version.Full() }

// IsRunning means a Service run is still owned, not that a model is reachable.
// It stays true after a stop timeout until the actual Run has exited.
func IsRunning() bool { mu.Lock(); defer mu.Unlock(); return running }

// IsStopping identifies a cancelled run whose cleanup is still in progress.
func IsStopping() bool { mu.Lock(); defer mu.Unlock(); return stopping }

// LastError returns a redacted service error.
func LastError() string { mu.Lock(); defer mu.Unlock(); return lastErr }

// Start parses and validates the TOML synchronously, then starts one Service.
// First-login failures are published through LastError; the app owns retries.
func Start(configTOML string) error {
	lifecycleMu.Lock()
	defer lifecycleMu.Unlock()
	installLogWriter()
	cleanupOnce.Do(cleanLegacyTempFiles)
	mu.Lock()
	occupied := svc != nil || running || stopping
	mu.Unlock()
	if occupied {
		return errors.New("frpc is already running or stopping")
	}
	if strings.TrimSpace(configTOML) == "" {
		return errors.New("empty config")
	}
	rememberSecrets(configTOML)
	runner, err := serviceFactory(configTOML)
	if err != nil {
		return safeError(err)
	}
	ctx, cancelFn := context.WithCancel(context.Background())
	doneCh := make(chan struct{})
	mu.Lock()
	svc = runner
	cancel = cancelFn
	done = doneCh
	running = true
	stopping = false
	closeInitiated = false
	lastErr = ""
	mu.Unlock()
	go func() {
		runErr := runner.Run(ctx)
		mu.Lock()
		if done == doneCh {
			if stopping {
				lastErr = ""
			} else if runErr != nil {
				lastErr = redactLocked(runErr.Error())
			}
			svc = nil
			cancel = nil
			done = nil
			running = false
			stopping = false
			closeInitiated = false
		}
		close(doneCh)
		mu.Unlock()
		cancelFn()
	}()
	return nil
}

// Stop requests cancellation before closing the Service and waits up to five
// seconds. It must be called off the iOS main thread. A timed-out run retains
// its handle and blocks Start until its actual cleanup completes.
func Stop() {
	lifecycleMu.Lock()
	defer lifecycleMu.Unlock()
	mu.Lock()
	runner, cancelFn, doneCh := svc, cancel, done
	if runner == nil {
		mu.Unlock()
		return
	}
	stopping = true
	initiate := !closeInitiated
	closeInitiated = true
	mu.Unlock()
	if cancelFn != nil {
		cancelFn()
	}
	if initiate {
		go runner.GracefulClose(0)
	}
	timer := time.NewTimer(stopTimeout)
	defer timer.Stop()
	select {
	case <-doneCh:
	case <-timer.C:
		mu.Lock()
		if done == doneCh {
			lastErr = "frpc is still stopping; wait for cleanup before starting again"
		}
		mu.Unlock()
	}
}

func newService(configTOML string) (serviceRunner, error) {
	loaded, err := loadConfig(configTOML)
	if err != nil {
		return nil, err
	}
	configSource := source.NewConfigSource()
	if err = configSource.ReplaceAll(loaded.proxies, loaded.visitors); err != nil {
		return nil, errors.New("invalid proxy or visitor configuration")
	}
	return client.NewService(client.ServiceOptions{
		Common:                 loaded.common,
		ConfigSourceAggregator: source.NewAggregator(configSource),
		UnsafeFeatures:         security.NewUnsafeFeatures(nil),
		// Deliberately no ConfigFilePath: reload/export endpoints may not read
		// a plaintext file that no longer exists. The app restarts with edits.
	})
}

// Clean only filenames produced by the previous version, within this process's
// temporary directory. No live new-version run uses such a file. On iOS that
// directory is the app sandbox; desktop runs never touch the shared temp area.
func cleanLegacyTempFiles() {
	// iOS gives this app a private temporary directory. On macOS the global
	// temp directory may also hold a different client's live configuration.
	if runtime.GOOS != "ios" {
		return
	}
	matches, _ := filepath.Glob(filepath.Join(os.TempDir(), "frpclient-*.toml"))
	for _, name := range matches {
		info, err := os.Lstat(name)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
			continue
		}
		_ = os.Remove(name)
	}
}

func rememberSecrets(configTOML string) {
	values := secretValues(configTOML)
	mu.Lock()
	defer mu.Unlock()
	for _, v := range values {
		if v == "" {
			continue
		}
		found := false
		for _, old := range redactions {
			if old == v {
				found = true
				break
			}
		}
		if !found {
			redactions = append(redactions, v)
		}
	}
}

func redactLocked(text string) string {
	for _, value := range redactions {
		text = strings.ReplaceAll(text, value, "[REDACTED]")
	}
	return text
}

func safeError(err error) error {
	if err == nil {
		return nil
	}
	mu.Lock()
	text := redactLocked(err.Error())
	mu.Unlock()
	return errors.New(text)
}
