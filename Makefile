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
#   make install              install all Phase 1 components
#   make install-test         install to PREFIX=/tmp/claude-sandbox-test (no real deploy)
#   make uninstall            remove installed files
#   make verify               sanity-check the installed setup
#   make help                 show this help

PREFIX      ?= /usr/local
USER_CONFIG ?= $(HOME)/.config
BIN_DIR     ?= $(PREFIX)/bin
SHARE_DIR   ?= $(PREFIX)/share/claude-sandbox
PROFILE_DIR ?= $(USER_CONFIG)/claude-sandbox/profiles

# Install map: source-in-repo -> dest-on-host
WRAPPER_SRC := sandbox/bin/claude-sandbox
WRAPPER_DST := $(BIN_DIR)/claude-sandbox

PROFILE_SRC := sandbox/profiles/default.yaml
PROFILE_DST := $(PROFILE_DIR)/default.yaml

ACL_SCRIPT_SRC := sandbox/scripts/setup-claude-session-acls.sh
ACL_SCRIPT_DST := $(SHARE_DIR)/scripts/setup-claude-session-acls.sh

INSTALLED_FILES := $(WRAPPER_DST) $(PROFILE_DST) $(ACL_SCRIPT_DST)

# Use install(1) for proper mode + atomic replace + dir creation
INSTALL          := install
INSTALL_PROGRAM  := $(INSTALL) -m 0755
INSTALL_DATA     := $(INSTALL) -m 0644
INSTALL_DIR      := $(INSTALL) -d -m 0755

# ── Targets ──────────────────────────────────────────────────────────────────

.PHONY: all install install-test uninstall verify help

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
	@echo ""
	@echo "Next steps:"
	@echo "  1. Run J121-ft3 (provision-claude-session.sh) to create the"
	@echo "     claude-session user, /etc/subuid map, and ACLs."
	@echo "  2. Complete claude-session's Anthropic OAuth on first invocation"
	@echo "     of: claude-sandbox -p \"hello\""
	@echo ""
	@echo "Until step 1 lands, claude-sandbox runs in same-UID degraded mode."

# Use PREFIX/USER_CONFIG overrides for safe non-destructive testing.
# Effectively: deploy everything under /tmp/claude-sandbox-test instead of
# the real install paths. Useful for verifying the install map without
# touching the host.
install-test:
	@echo "Test install to /tmp/claude-sandbox-test ..."
	@$(MAKE) install \
		PREFIX=/tmp/claude-sandbox-test \
		USER_CONFIG=/tmp/claude-sandbox-test/config
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

$(PROFILE_DST): $(PROFILE_SRC)
	@$(INSTALL_DIR) $(dir $@)
	$(INSTALL_DATA) $< $@

$(ACL_SCRIPT_DST): $(ACL_SCRIPT_SRC)
	@$(INSTALL_DIR) $(dir $@)
	$(INSTALL_PROGRAM) $< $@
