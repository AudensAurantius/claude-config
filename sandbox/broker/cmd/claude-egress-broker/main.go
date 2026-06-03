// Command claude-egress-broker is the Go production egress broker
// (ClaudeConfig-ciw.2 slice 6). Parity reference: the Python broker at
// src/claude_config/egress_broker/__main__.py.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/credentials"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/handler"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/notify"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/policy"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/server"
)

func main() {
	policyDir := flag.String("policy-dir", "/etc/claude-config/egress-policy", "Directory of per-alias YAML policy files.")
	socket := flag.String("socket", "", "UDS path to bind (ignored under systemd socket activation).")
	peerUID := flag.Int("peer-uid", -1, "Expected peer UID (claude-session). Required.")
	loglevel := flag.String("loglevel", "INFO", "Log verbosity: DEBUG, INFO, WARN, ERROR.")
	flag.Parse()

	logger := newLogger(*loglevel)
	slog.SetDefault(logger)

	if *peerUID < 0 {
		fmt.Fprintln(os.Stderr, "claude-egress-broker: --peer-uid is required")
		os.Exit(2)
	}

	policies, err := policy.LoadDirectory(*policyDir)
	if err != nil {
		logger.Error("policy load failed", "err", err)
		os.Exit(1)
	}
	if policies.Len() == 0 {
		logger.Error("policy directory contains no aliases; refusing to start", "dir", *policyDir)
		os.Exit(1)
	}

	backend := credentials.NewPassBackend()
	h := handler.New(policies, backend)

	cfg := server.Config{
		SocketPath:      *socket,
		ExpectedPeerUID: *peerUID,
		Logger:          logger,
	}

	logger.Info("starting broker",
		"aliases", policies.Len(),
		"backend", backend.Name(),
		"peer_uid", *peerUID,
	)

	if err := notify.Ready(); err != nil {
		logger.Warn("sd_notify READY failed", "err", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if err := server.Serve(ctx, cfg, h); err != nil {
		logger.Error("server stopped with error", "err", err)
		_ = notify.Stopping()
		os.Exit(1)
	}
	_ = notify.Stopping()
	logger.Info("broker shut down cleanly")
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
