// Command claude-egress-proxy is the SNI-passthrough proxy that
// enforces a domain allowlist on uncredentialed outbound TLS from the
// sandbox (DEC-013, ClaudeConfig-ciw.3). It reads the SNI from each
// connection's ClientHello, checks the allowlist, and either splices
// the bytes through to the upstream or drops the connection.
package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/AudensAurantius/claude-config/sandbox/proxy/internal/notify"
	"github.com/AudensAurantius/claude-config/sandbox/proxy/internal/policy"
	"github.com/AudensAurantius/claude-config/sandbox/proxy/internal/server"
)

func main() {
	policyDir := flag.String("policy-dir", "/etc/claude-config/egress-proxy", "Directory of per-alias YAML allowlist files.")
	listen := flag.String("listen", "", "TCP listen address (e.g. 127.0.0.1:8443). Ignored when --listen-fds is set.")
	listenFDs := flag.Bool("listen-fds", false, "Adopt fd 3 from systemd socket activation.")
	defaultPort := flag.Int("default-port", 443, "Upstream port the proxy splices to (the proxy listens on whatever port systemd gives it).")
	peekTimeout := flag.Duration("peek-timeout", 5*time.Second, "Maximum time to wait for the ClientHello.")
	dialTimeout := flag.Duration("dial-timeout", 5*time.Second, "Upstream connect timeout.")
	loglevel := flag.String("loglevel", "INFO", "Log verbosity: DEBUG, INFO, WARN, ERROR.")
	flag.Parse()

	logger := newLogger(*loglevel)
	slog.SetDefault(logger)

	policies, err := policy.LoadDirectory(*policyDir)
	if err != nil {
		logger.Error("policy load failed", "err", err)
		os.Exit(1)
	}
	if policies.Len() == 0 {
		logger.Error("policy directory contains no aliases; refusing to start", "dir", *policyDir)
		os.Exit(1)
	}

	cfg := server.Config{
		ListenAddr:  *listen,
		ListenFDs:   *listenFDs,
		PeekTimeout: *peekTimeout,
		DialTimeout: *dialTimeout,
		DefaultPort: *defaultPort,
		Logger:      logger,
		Policies:    policies,
	}

	logger.Info("starting proxy",
		"aliases", policies.Len(),
		"alias_list", policies.Aliases(),
		"default_port", *defaultPort,
	)

	if err := notify.Ready(); err != nil {
		logger.Warn("sd_notify READY failed", "err", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if err := server.Serve(ctx, cfg); err != nil {
		logger.Error("server stopped with error", "err", err)
		_ = notify.Stopping()
		os.Exit(1)
	}
	_ = notify.Stopping()
	logger.Info("proxy shut down cleanly")
}

func newLogger(level string) *slog.Logger {
	var lv slog.Level
	switch level {
	case "DEBUG":
		lv = slog.LevelDebug
	case "WARN":
		lv = slog.LevelWarn
	case "ERROR":
		lv = slog.LevelError
	default:
		lv = slog.LevelInfo
	}
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: lv}))
}
