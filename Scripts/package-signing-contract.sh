#!/usr/bin/env bash
# Shared, side-effect-free signing invariants for package-app.sh and its hermetic regression test.
# This file is sourced; keep every public symbol under the devtype_ prefix.

devtype_entitlements_hash() {
  local plist="$1"
  # plistlib recursively sorts dictionary keys before emitting a binary plist. Hashing a raw/XML
  # or `plutil` conversion would make semantically identical dictionaries depend on key order.
  python3 -c 'import plistlib, sys; value = plistlib.load(open(sys.argv[1], "rb")); sys.stdout.buffer.write(plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True))' "${plist}" \
    | shasum -a 256 \
    | awk '{print $1}'
}

devtype_empty_entitlements_hash() {
  python3 -c 'import plistlib, sys; sys.stdout.buffer.write(plistlib.dumps({}, fmt=plistlib.FMT_BINARY, sort_keys=True))' \
    | shasum -a 256 \
    | awk '{print $1}'
}

# `codesign --xml --entitlements -` emits no payload when the signature has no entitlement blob.
# Treat that as an empty dictionary, which is semantically identical to an empty source plist.
devtype_signed_entitlements_hash() {
  local signed_target="$1"
  local extracted
  local command_status
  local hash_status

  extracted="$(mktemp -t devtype-signed-entitlements)" || return 1
  if codesign -d --xml --entitlements - "${signed_target}" \
      >"${extracted}" 2>/dev/null; then
    command_status=0
  else
    command_status=$?
  fi
  if [[ "${command_status}" -ne 0 ]]; then
    rm -f "${extracted}"
    return "${command_status}"
  fi

  if [[ -s "${extracted}" ]]; then
    if devtype_entitlements_hash "${extracted}"; then
      hash_status=0
    else
      hash_status=$?
    fi
  else
    if devtype_empty_entitlements_hash; then
      hash_status=0
    else
      hash_status=$?
    fi
  fi
  rm -f "${extracted}"
  return "${hash_status}"
}

devtype_signed_entitlements_match() {
  local source_plist="$1"
  local signed_target="$2"
  local expected_hash
  local embedded_hash

  expected_hash="$(devtype_entitlements_hash "${source_plist}")" || return 1
  embedded_hash="$(devtype_signed_entitlements_hash "${signed_target}")" || return 1
  [[ "${embedded_hash}" == "${expected_hash}" ]]
}

devtype_entitlements_stamp_matches() {
  local source_plist="$1"
  local stamp="$2"
  local expected_hash
  local stamped_hash

  [[ -f "${stamp}" ]] || return 1
  expected_hash="$(devtype_entitlements_hash "${source_plist}")" || return 1
  stamped_hash="$(tr -d '[:space:]' < "${stamp}")"
  [[ "${#stamped_hash}" -eq 64 && "${stamped_hash}" != *[!0-9a-f]* ]] || return 1
  [[ "${stamped_hash}" == "${expected_hash}" ]]
}

# The skip-resign path is allowed only when both the successful-package stamp and the actual
# signature describe the current source entitlement set. Either signal alone can be stale.
devtype_entitlements_are_current() {
  local source_plist="$1"
  local stamp="$2"
  local signed_target="$3"

  devtype_entitlements_stamp_matches "${source_plist}" "${stamp}" \
    && devtype_signed_entitlements_match "${source_plist}" "${signed_target}"
}

devtype_effective_hardened_runtime() {
  local requested="$1"
  local sign_kind="$2"

  case "${requested}" in
    auto)
      if [[ "${sign_kind}" == "developer-id" ]]; then
        printf '1\n'
      else
        printf '0\n'
      fi
      ;;
    0|1)
      printf '%s\n' "${requested}"
      ;;
    *)
      return 1
      ;;
  esac
}

devtype_bundle_hardened_runtime_matches() {
  local signed_target="$1"
  local required="$2"
  local signing_info

  signing_info="$(codesign -dv "${signed_target}" 2>&1)" || return 1
  case "${required}" in
    1)
      grep -q 'flags=.*runtime' <<<"${signing_info}"
      ;;
    0)
      ! grep -q 'flags=.*runtime' <<<"${signing_info}"
      ;;
    *)
      return 1
      ;;
  esac
}
