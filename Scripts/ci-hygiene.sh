#!/usr/bin/env bash
# Repo hygiene shared by GitHub Actions and Scripts/ci-local.sh.
# Syntax, plists, publication fixtures, and the localization fast-fail.
# The Swift suite is a separate job; this script does not compile it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

echo "==> Shell script syntax"
for f in Scripts/*.sh; do
  bash -n "$f" || { echo "error: syntax check failed for $f" >&2; exit 1; }
done
if [[ -f "./ci:local" ]]; then
  bash -n "./ci:local" || { echo "error: syntax check failed for ./ci:local" >&2; exit 1; }
fi

echo "==> Property lists"
plutil -lint Resources/Info.plist
plutil -lint Resources/DevType.entitlements
for f in Resources/*.lproj/InfoPlist.strings; do
  plutil -lint "$f"
done

echo "==> Release, installer, and publication fixtures"
./Scripts/ci-release-fixtures.sh

echo "==> Localization table parity"
# LocalizationParityTests is the real assertion. This fails the hygiene job
# before that suite when Korean is dropped from the language enum or a
# strings file is not a property list. A missing key falls back to English;
# a mismatched format specifier crashes String(format:).
grep -c 'case ko' Sources/ExpanderEngine/Localization/LocalizationManager.swift >/dev/null
for f in Sources/ExpanderEngine/Localization/Resources/*.lproj/*.strings; do
  plutil -lint "$f"
done

echo "==> Hygiene passed"
