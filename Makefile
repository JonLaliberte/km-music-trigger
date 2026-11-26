BIN      := km-music-trigger
PREFIX   ?= $(HOME)/.local
BINDIR   := $(PREFIX)/bin
LABEL    := com.github.jonlaliberte.km-music-trigger
PLIST    := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG      := $(HOME)/Library/Logs/km-music-trigger.log
UID_     := $(shell id -u)

ON       ?= playing,paused,stopped
JSON     ?= 0

.PHONY: build install agent status uninstall clean

build: build/$(BIN)

build/$(BIN): Sources/main.swift
	@mkdir -p build
	swiftc -O -o $@ $<

install: build
	@mkdir -p $(BINDIR)
	cp build/$(BIN) $(BINDIR)/$(BIN)
	@echo "Installed $(BINDIR)/$(BIN)"

agent: install
	@test -n "$(MACRO)" || { echo "Usage: make agent MACRO=<macro name or UUID> [ON=playing,paused] [JSON=1]"; exit 1; }
	@mkdir -p $(dir $(PLIST))
	sed -e 's|__BIN__|$(BINDIR)/$(BIN)|' -e 's|__LABEL__|$(LABEL)|' -e 's|__LOG__|$(LOG)|' \
	    -e 's|__MACRO__|$(MACRO)|' -e 's|__ON__|$(ON)|' -e 's|__JSON__|$(JSON)|' \
	    launchd/agent.plist.template > $(PLIST)
	-launchctl bootout gui/$(UID_)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$(UID_) $(PLIST)
	@echo "Loaded $(LABEL). Log: $(LOG)"

status:
	@launchctl print gui/$(UID_)/$(LABEL) 2>/dev/null | grep -E "state =|pid =|last exit" || echo "not loaded"
	@tail -5 $(LOG) 2>/dev/null || true

uninstall:
	-launchctl bootout gui/$(UID_)/$(LABEL) 2>/dev/null
	rm -f $(PLIST) $(BINDIR)/$(BIN)

clean:
	rm -rf build
