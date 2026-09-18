#!/bin/bash
# Pure-function tests for TerminalFocus (Herdr session matching, attach
# discovery from ps, connected-machine navigation, remote-argument hygiene): compiles the production files
# against the test's stub collaborators. No app, no Herdr, no terminal needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${TMPDIR:-/tmp}/agentbar-terminal-focus-test"
swiftc Scripts/test/terminal-focus-test.swift Sources/AgentBar/TerminalFocus.swift \
  Sources/AgentBar/HerdrMachineNavigation.swift \
  -o "$BIN" -framework Cocoa
"$BIN"
echo "terminal-focus-test: ok"
