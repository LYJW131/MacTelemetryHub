#!/usr/bin/env bash
# Pull the protocol contract from the anker-prime-ble debug repository.
#
# That repository is where the field maps were established and where the Python
# implementation lives; this one only reimplements the decoding in Swift. The
# generated constants and the decoded-state fixtures come from there so the two
# cannot drift apart silently. Everything this writes is generated — never edit
# the copies, fix the source and re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${ANKER_PRIME_BLE_REPO:-$HOME/Desktop/anker-prime-ble}"
if [[ ! -d "$SOURCE" ]]; then
  echo "debug repo not found at $SOURCE" >&2
  echo "clone https://github.com/LYJW131/anker-prime-ble or set ANKER_PRIME_BLE_REPO" >&2
  exit 1
fi

python3 "$SOURCE/tools/contract.py" verify >/dev/null || {
  echo "contract in $SOURCE is stale — run tools/contract.py export there first" >&2
  exit 1
}

mkdir -p Tests/ChargerTelemetryKitTests/Contract
rsync -a --delete "$SOURCE/spec/fixtures/" Tests/ChargerTelemetryKitTests/Contract/fixtures/
rsync -a --delete "$SOURCE/captures/" Tests/ChargerTelemetryKitTests/Contract/captures/
cp "$SOURCE/spec/AnkerPrimeSpec.swift" Sources/ChargerTelemetryKit/AnkerPrimeSpec.swift

echo "synced $(ls Tests/ChargerTelemetryKitTests/Contract/fixtures/*.json | wc -l | tr -d ' ') fixtures"
