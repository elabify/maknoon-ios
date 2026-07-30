#!/usr/bin/env bash
#
# Public-mirror leak scan. Runs in the PUBLIC app repos (maknoon-ios,
# maknoon-android) as defence in depth: the authoritative gate is
# scripts/publish-mirror/leak-gate.sh, which runs fail-closed in the private
# monorepo BEFORE anything is pushed. This second pass catches content that
# arrives in a public repo by another route, most importantly a contributor pull
# request, which the private gate never sees.
#
# Placed in both app mirrors as .github/leak-scan.sh so the pattern list has ONE
# definition. It used to be inlined in the Android workflow and absent from the
# iOS one; two inline copies across two workflows (each needing it twice, once
# for branches and once inside the gated release job) is four copies to drift.
#
# Run locally from a mirror checkout, or from the monorepo against a staging tree:
#     bash .github/leak-scan.sh [path]      # default: .
#
# LEAK_SCAN_INSCOPE (space-separated) drops components from the forbidden-path
# set for one repo, mirroring MIRROR_INSCOPE_DIRS in the private leak-gate.sh.
# musnad-contracts sets it to `smart-contracts`, which it legitimately ships.
#
set -uo pipefail

TARGET="${1:-.}"

# Components that live only upstream and must never appear in a public mirror, minus
# whatever this repo legitimately ships. Deliberately omits the trees that are
# always mirrored (ios-app-maknoon, android-app-elabify, android-sdk-musnad,
# elabify-core, the ledger/trezor crates).
ALL_COMPONENTS="issuer-backend verifier-server vault-plugin smart-contracts demo-web-app ios-sdk-musnad"
inscope=" ${LEAK_SCAN_INSCOPE:-} "
oos=()
for c in $ALL_COMPONENTS; do
  case "$inscope" in *" $c "*) ;; *) oos+=("$c") ;; esac
done
oos_alt="$(IFS='|'; echo "${oos[*]}")"

# Patterns use char-classes (e.g. [/]) so this file does not itself contain the
# literal forbidden strings it scans for.
patterns=(
  # Boundary-anchored so a mirror may name ITSELF (elabify/musnad-contracts)
  # while the upstream slug stays forbidden in every form it actually occurs.
  'elabify[/]musnad([^-A-Za-z0-9_]|$)'
  'BEGIN [A-Z ]*PRIVATE[ ]KEY'
  'OPENSSH[ ]PRIVATE[ ]KEY'
  'ghp_[0-9A-Za-z]{30,}'
  'AKIA[0-9A-Z]{16}'
  'xox[baprs]-[0-9A-Za-z-]{8,}'
  'CARGO_REGISTRY[_]TOKEN'
  'docs/(decisions|operations|integrations|reference)/'
  "(\\.\\.[/]|code[/])($oos_alt)"
)

fail=0
for p in "${patterns[@]}"; do
  # Exclude this script itself: it necessarily contains the patterns.
  hits="$(grep -rEnI --exclude-dir=.git --exclude='leak-scan.sh' "$p" "$TARGET" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "::error::forbidden pattern matched: /$p/"
    echo "$hits" | head -20
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "leak scan clean"
else
  exit 1
fi
