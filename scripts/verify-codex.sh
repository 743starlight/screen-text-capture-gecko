#!/bin/bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
mkdir -p .build/verification
xcrun swiftc -module-cache-path .build/verification/ModuleCache -o .build/verification/verify-codex \
  screentextcapture/OCRTypes.swift screentextcapture/GlobalShortcut.swift \
  screentextcapture/VisionOCR.swift screentextcapture/CLIProcess.swift \
  screentextcapture/SubscriptionOCR.swift screentextcapture/ModelDiscovery.swift scripts/verify-codex.swift
.build/verification/verify-codex "$@"
