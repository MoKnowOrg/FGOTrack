#!/bin/zsh
set -eu
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -module-cache-path "$test_dir/cache" "$repo_dir/FGOTrack/Ledger.swift" "$repo_dir/FGOTrack/ReceiptAmountParser.swift" "$repo_dir/FGOTrack/ReceiptSuggestions.swift" "$repo_dir/FGOTrack/ReceiptIntelligence.swift" "$repo_dir/Tests/ReceiptIntelligenceSmoke.swift" -o "$test_dir/receipt-ai-smoke"
"$test_dir/receipt-ai-smoke"
