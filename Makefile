# Makefile — claude-config Phase 1 installer.
#
# Deploys the claude-sandbox wrapper, default profile, and supporting
# scripts to canonical host locations per DEC-004 (installer-based
# deployment with non-destructive defaults). Phase 1 components only;
# Phase 2+ targets layer in as those phases ship.
#
# Variables (override on command line: `make install PREFIX=/tmp/test`):
#   PREFIX        install root for system-wide bits (default /usr/local)
#   USER_CONFIG   user-config root (default $HOME/.config)
#   BIN_DIR       wrapper destination (default $(PREFIX)/bin)
#   SHARE_DIR     shared support files (default $(PREFIX)/share/claude-sandbox)
#   PROFILE_DIR   profile destination (default $(USER_CONFIG)/claude-sandbox/profiles)
#
# Targets:
#   make install              install all Phase 1 components (files only)
#   make provision            create claude-session user + subuid + ACLs (sudo)
#   make unprovision          reverse `make provision` (sudo)
#   make install-test         install to PREFIX=/tmp/claude-sandbox-test (no real deploy)
#   make uninstall            remove installed files (does NOT unprovision)
#   make verify               sanity-check the installed setup
#   make help                 show this help

PREFIX      ?= /usr/local
USER_CONFIG ?= $(HOME)/.config
BIN_DIR     ?= $(PREFIX)/bin
SHARE_DIR   ?= $(PREFIX)/share/claude-sandbox
PROFILE_DIR ?= $(USER_CONFIG)/claude-sandbox/profiles
ETC_DIR     ?= /etc/claude-code

# Install map: source-in-repo -> dest-on-host
WRAPPER_SRC := sandbox/bin/claude-sandbox
WRAPPER_DST := $(BIN_DIR)/claude-sandbox

# Composed-mode srt-settings emitter (invoked by the wrapper; must sit
# beside it so the wrapper's SELF_DIR lookup resolves it).
EMITTER_SRC := sandbox/bin/claude-sandbox-emit-srt-settings
EMITTER_DST := $(BIN_DIR)/claude-sandbox-emit-srt-settings

PROFILE_SRC := sandbox/profiles/default.yaml
PROFILE_DST := $(PROFILE_DIR)/default.yaml

# Claude Code managed settings (system-wide, root-owned): locks off auto
# mode host-wide (ClaudeConfig-40s.20 / DEC). NB: claude-session-scoped
# permission deny rules (e.g. Read(**/.env)) are NOT here — they live in
# claude-session's own settings, delivered by ClaudeConfig-40s.15.8.
MANAGED_SETTINGS_SRC := claude/settings/managed-settings.json
MANAGED_SETTINGS_DST := $(ETC_DIR)/managed-settings.json

ACL_SCRIPT_SRC := sandbox/scripts/setup-claude-session-acls.sh
ACL_SCRIPT_DST := $(SHARE_DIR)/scripts/setup-claude-session-acls.sh

PROVISION_SRC  := sandbox/scripts/provision-claude-session.sh
PROVISION_DST  := $(SHARE_DIR)/scripts/provision-claude-session.sh

INSTALLED_FILES := $(WRAPPER_DST) $(EMITTER_DST) $(PROFILE_DST) $(MANAGED_SETTINGS_DST) $(ACL_SCRIPT_DST) $(PROVISION_DST)

# Use install(1) for proper mode + atomic replace + dir creation
INSTALL          := install
INSTALL_PROGRAM  := $(INSTALL) -m 0755
INSTALL_DATA     := $(INSTALL) -m 0644
INSTALL_DIR      := $(INSTALL) -d -m 0755

# ── Targets ──────────────────────────────────────────────────────────────────

.PHONY: all install install-test uninstall verify help provision unprovision

all: help

help:
	@sed -n '/^# Makefile/,/^$$/p' Makefile | sed 's/^# \{0,1\}//'

install: $(INSTALLED_FILES)
	@echo ""
	@echo "✓ claude-config Phase 1 installed."
	@echo ""
	@echo "  Wrapper:    $(WRAPPER_DST)"
	@echo "  Profile:    $(PROFILE_DST)"
	@echo "  ACL script: $(ACL_SCRIPT_DST)"
	@echo "  Provision:  $(PROVISION_DST)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Run \`make provision\` (or invoke $(PROVISION_DST) directly)"
	@echo "     to create the claude-session user, /etc/subuid map, and ACLs."
	@echo "  2. Complete claude-session's Anthropic OAuth on first invocation"
	@echo "     of: claude-sandbox -p \"hello\""
	@echo ""
	@echo "Until step 1 lands, claude-sandbox runs in same-UID degraded mode."

# Provisioning targets are sudo-mediated and mutate system state
# (/etc/passwd, /etc/subuid, /etc/subgid, ACLs on ~/.claude/projects/).
# Kept separate from `install` so the file-deploy step stays safe to
# re-run unattended. The provision script re-execs itself under sudo
# when invoked unprivileged, so we don't sudo from the Makefile.

provision: $(PROVISION_DST) $(ACL_SCRIPT_DST)
	@echo "Provisioning claude-session (will prompt for sudo) ..."
	$(PROVISION_DST) --acl-script $(ACL_SCRIPT_DST)

unprovision: $(PROVISION_DST) $(ACL_SCRIPT_DST)
	@echo "Un-provisioning claude-session (will prompt for sudo) ..."
	$(PROVISION_DST) --uninstall --acl-script $(ACL_SCRIPT_DST)

# Use PREFIX/USER_CONFIG overrides for safe non-destructive testing.
# Effectively: deploy everything under /tmp/claude-sandbox-test instead of
# the real install paths. Useful for verifying the install map without
# touching the host.
install-test:
	@echo "Test install to /tmp/claude-sandbox-test ..."
	@$(MAKE) install \
		PREFIX=/tmp/claude-sandbox-test \
		USER_CONFIG=/tmp/claude-sandbox-test/config \
		ETC_DIR=/tmp/claude-sandbox-test/etc/claude-code
	@echo ""
	@echo "Test artifacts under /tmp/claude-sandbox-test/. Inspect with:"
	@echo "  find /tmp/claude-sandbox-test -type f"

uninstall:
	@echo "Removing installed files ..."
	@for f in $(INSTALLED_FILES); do \
		if [ -e "$$f" ]; then \
			echo "  rm $$f"; \
			rm -f "$$f"; \
		fi; \
	done
	@echo "✓ Uninstalled. (Empty parent dirs not removed.)"

verify:
	@echo "Verifying claude-config Phase 1 install ..."
	@for f in $(INSTALLED_FILES); do \
		if [ -e "$$f" ]; then \
			echo "  ✓ present: $$f"; \
		else \
			echo "  ✗ MISSING: $$f"; \
		fi; \
	done
	@if [ -x $(WRAPPER_DST) ]; then \
		echo ""; \
		echo "Wrapper version:"; \
		$(WRAPPER_DST) --version 2>&1 | sed 's/^/  /'; \
	fi

# ── Install rules ────────────────────────────────────────────────────────────

$(WRAPPER_DST): $(WRAPPER_SRC)
	@$(INSTALL_DIR) $(dir $@)
	$(INSTALL_PROGRAM) $< $@

$(EMITTER_DST): $(EMITTER_SRC)
	@$(INSTALL_DIR) $(dir $@)
	$(INSTALL_PROGRAM) $< $@

$(PROFILE_DST): $(PROFILE_SRC)
	@$(INSTALL_DIR) $(dir $@)
	$(INSTALL_DATA) $< $@

$(MANAGED_SETTINGS_DST): $(MANAGED_SETTINGS_SRC)
	@$(INSTALL_DIR) $(dir $@)
	$(INSTALL_DATA) $< $@

$(ACL_SCRIPT_DST): $(ACL_SCRIPT_SRC)
	@$(INSTALL_DIR) $(dir $@)
	$(INSTALL_PROGRAM) $< $@

$(PROVISION_DST): $(PROVISION_SRC)
	@$(INSTALL_DIR) $(dir $@)
	$(INSTALL_PROGRAM) $< $@
