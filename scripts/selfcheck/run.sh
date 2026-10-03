#!/bin/bash
# Compiles the non-UI sources with main.swift and runs the self-checks.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$(mktemp -d)/selfcheck"
swiftc -o "$out" scripts/selfcheck/main.swift \
  MacTaskScheduler/Models/*.swift MacTaskScheduler/Services/*.swift MacTaskScheduler/Utilities/*.swift
"$out"
