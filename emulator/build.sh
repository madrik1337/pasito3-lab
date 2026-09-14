#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc Core.swift main.swift -framework CoreBluetooth -o build/PasitoEmulator
echo "Built: $(pwd)/build/PasitoEmulator"
