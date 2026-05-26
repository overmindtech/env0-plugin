#!/bin/sh
# Unit tests for the verify_attestation helper in env0.plugin.yaml.
#
# Exercises the helper against real GitHub Artifact Attestations on the
# Sigstore public-good instance. Expects outbound HTTPS to api.github.com,
# objects.githubusercontent.com, tuf-repo-cdn.sigstore.dev, rekor.sigstore.dev.
#
# Run with: sh tests/verify-attestation.sh
#
# Requires: yq, jq, curl, awk, sha256sum or shasum, plus either `gh` (>= 2.49)
# on PATH or a network-reachable cosign download path.
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PLUGIN="${REPO_ROOT}/env0.plugin.yaml"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=""

note()  { printf '\n=== %s ===\n' "$*"; }
pass()  { TESTS_PASSED=$((TESTS_PASSED + 1)); printf '  PASS: %s\n' "$*"; }
fail()  { TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED_NAMES="${FAILED_NAMES} $1"; printf '  FAIL: %s\n' "$*"; }

# assert_rc <expected_rc> <actual_rc> <name>
assert_rc() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$1" = "$2" ]; then
        pass "$3 (rc=$2)"
    else
        fail "$3 (expected rc=$1, got rc=$2)"
    fi
}

# require_cmd <cmd> ...
require_cmd() {
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            echo "fatal: missing required tool: $c" >&2
            exit 2
        fi
    done
}

require_cmd yq jq curl awk
if ! command -v sha256sum >/dev/null 2>&1 \
   && ! command -v shasum >/dev/null 2>&1 \
   && ! command -v openssl >/dev/null 2>&1; then
    echo "fatal: need one of sha256sum, shasum, or openssl" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Extract the helper functions from the plugin YAML and source them into a
# subshell. We slice from `ATTESTATION_FAIL_EXIT=` (the first module-level
# constant we add) to the start of `main_script() {`, then strip the
# main_script line itself. This mirrors what the smoke section of the plan
# describes and what validate-shell.yml does for shellcheck.
# ---------------------------------------------------------------------------
EXTRACTED=$(mktemp)
trap 'rm -f "${EXTRACTED}"' EXIT
yq eval -r '.run.exec' "${PLUGIN}" \
    | awk '/^[[:space:]]*ATTESTATION_FAIL_EXIT=/,/^[[:space:]]*main_script\(\) \{/' \
    | sed '/^[[:space:]]*main_script() {/d' > "${EXTRACTED}"

if [ ! -s "${EXTRACTED}" ]; then
    echo "fatal: could not extract verify_attestation helpers from ${PLUGIN}" >&2
    exit 2
fi

# Map host OS/ARCH onto the same labels env0.plugin.yaml uses, so the helper
# can decide which cosign asset to download.
host_os=$(uname -s)
host_arch=$(uname -m)
case "${host_arch}" in
    x86_64|amd64) host_arch="x86_64" ;;
    aarch64|arm64) host_arch="arm64" ;;
    i386|i686) host_arch="i386" ;;
esac

# Build a PATH that does NOT contain `gh`, used by the cosign-fallback tests.
NO_GH_PATH=""
old_ifs="${IFS}"; IFS=:
for p in ${PATH}; do
    [ -z "${p}" ] && continue
    [ -x "${p}/gh" ] && continue
    if [ -z "${NO_GH_PATH}" ]; then NO_GH_PATH="${p}"; else NO_GH_PATH="${NO_GH_PATH}:${p}"; fi
done
IFS="${old_ifs}"

# ---------------------------------------------------------------------------
# Per-test sandbox helpers
# ---------------------------------------------------------------------------
overmind_filename_for_host() {
    case "${host_os}_${host_arch}" in
        Linux_x86_64)   echo "overmind_cli_Linux_x86_64.tar.gz" ;;
        Linux_arm64)    echo "overmind_cli_Linux_arm64.tar.gz" ;;
        Darwin_x86_64)  echo "overmind_cli_Darwin_x86_64.tar.gz" ;;
        Darwin_arm64)   echo "overmind_cli_Darwin_arm64.tar.gz" ;;
        *)              return 1 ;;
    esac
}

OVERMIND_FILE=$(overmind_filename_for_host) || {
    echo "fatal: no published Overmind CLI archive for host ${host_os}/${host_arch}" >&2
    exit 2
}

# Download once and cache for the duration of the test run.
SHARED_DIR=$(mktemp -d)
trap 'rm -rf "${SHARED_DIR}" "${EXTRACTED}"' EXIT
echo "Downloading ${OVERMIND_FILE}..."
curl -fsSL "https://github.com/overmindtech/cli/releases/latest/download/${OVERMIND_FILE}" \
    -o "${SHARED_DIR}/overmind-archive"

# Tiny gh asset for the cross-repo test. We don't need to install gh, just
# verify a real cli/cli archive exists and is attested. Use linux_amd64 because
# it's small and we never extract it.
GH_TAG=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name')
GH_VERSION=${GH_TAG#v}
echo "Downloading gh ${GH_TAG} (linux amd64) for cross-repo test..."
curl -fsSL "https://github.com/cli/cli/releases/download/${GH_TAG}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    -o "${SHARED_DIR}/gh-archive"

# Unique fixture for the missing-attestation test: 64 random bytes that GitHub
# has never seen, so the attestations endpoint returns an empty list.
dd if=/dev/urandom bs=1 count=64 of="${SHARED_DIR}/random-fixture" 2>/dev/null

# ---------------------------------------------------------------------------
# Per-test helper: run a verify_attestation invocation in a clean subshell
# with controlled PATH and OS/ARCH, capture its rc. stderr/stdout pass through
# so failure messages are visible.
# ---------------------------------------------------------------------------
run_verify() {
    # args: <archive> <repo> <wf_path> <path-mode>
    # path-mode: "default" (current PATH) or "no-gh" (PATH stripped of gh)
    _archive="$1"; _repo="$2"; _wf="$3"; _path_mode="$4"
    case "${_path_mode}" in
        default) _path="${PATH}" ;;
        no-gh)   _path="${NO_GH_PATH}" ;;
        *)       echo "bad path-mode: ${_path_mode}" >&2; return 2 ;;
    esac
    set +e
    PATH="${_path}" \
        OS="${host_os}" \
        ARCH="${host_arch}" \
        sh -c '. "$1"; verify_attestation "$2" "$3" "$4"' _ "${EXTRACTED}" "${_archive}" "${_repo}" "${_wf}"
    _rc=$?
    set -e
    return "${_rc}"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Skip cosign tests if the host platform doesn't have a published cosign binary.
host_has_cosign() {
    case "${host_os}_${host_arch}" in
        Linux_x86_64|Linux_arm64|Darwin_x86_64|Darwin_arm64) return 0 ;;
        *) return 1 ;;
    esac
}

note "1/9 gh happy path — Overmind CLI archive verifies via gh"
if command -v gh >/dev/null 2>&1; then
    cp "${SHARED_DIR}/overmind-archive" "${SHARED_DIR}/t1-archive"
    run_verify "${SHARED_DIR}/t1-archive" "overmindtech/cli" ".github/workflows/release.yml" default || rc=$?
    rc=${rc:-0}
    assert_rc 0 "${rc}" "gh happy path"
    unset rc
else
    echo "  SKIP: gh not on PATH"
fi

note "2/9 cosign fallback — Overmind CLI archive verifies via cosign when gh absent"
if host_has_cosign; then
    cp "${SHARED_DIR}/overmind-archive" "${SHARED_DIR}/t2-archive"
    run_verify "${SHARED_DIR}/t2-archive" "overmindtech/cli" ".github/workflows/release.yml" no-gh || rc=$?
    rc=${rc:-0}
    assert_rc 0 "${rc}" "cosign fallback happy path"
    unset rc
else
    echo "  SKIP: no published cosign binary for ${host_os}/${host_arch}"
fi

note "3/9 tamper detection — flipped byte must fail (gh path)"
if command -v gh >/dev/null 2>&1; then
    cp "${SHARED_DIR}/overmind-archive" "${SHARED_DIR}/t3-archive"
    printf '\x00' >> "${SHARED_DIR}/t3-archive"
    run_verify "${SHARED_DIR}/t3-archive" "overmindtech/cli" ".github/workflows/release.yml" default || rc=$?
    rc=${rc:-0}
    assert_rc 99 "${rc}" "tamper detection (gh)"
    unset rc
else
    echo "  SKIP: gh not on PATH"
fi

note "4/9 tamper detection — flipped byte must fail (cosign path)"
if host_has_cosign; then
    cp "${SHARED_DIR}/overmind-archive" "${SHARED_DIR}/t4-archive"
    printf '\x00' >> "${SHARED_DIR}/t4-archive"
    run_verify "${SHARED_DIR}/t4-archive" "overmindtech/cli" ".github/workflows/release.yml" no-gh || rc=$?
    rc=${rc:-0}
    assert_rc 99 "${rc}" "tamper detection (cosign)"
    unset rc
else
    echo "  SKIP: no published cosign binary for ${host_os}/${host_arch}"
fi

note "5/9 wrong signer-workflow — fake workflow path must fail"
if command -v gh >/dev/null 2>&1; then
    cp "${SHARED_DIR}/overmind-archive" "${SHARED_DIR}/t5-archive"
    run_verify "${SHARED_DIR}/t5-archive" "overmindtech/cli" ".github/workflows/notreal.yml" default || rc=$?
    rc=${rc:-0}
    assert_rc 99 "${rc}" "wrong signer-workflow (gh) — proves identity pin works"
    unset rc
else
    echo "  SKIP: gh not on PATH"
fi

note "6/9 wrong repo — verifying cli/cli archive as overmindtech/cli must fail"
if command -v gh >/dev/null 2>&1; then
    cp "${SHARED_DIR}/gh-archive" "${SHARED_DIR}/t6-archive"
    run_verify "${SHARED_DIR}/t6-archive" "overmindtech/cli" ".github/workflows/release.yml" default || rc=$?
    rc=${rc:-0}
    assert_rc 99 "${rc}" "cross-repo confusion (gh)"
    unset rc
else
    echo "  SKIP: gh not on PATH"
fi

note "7/9 missing attestation — random fixture has no attestation, must fail (cosign path)"
if host_has_cosign; then
    cp "${SHARED_DIR}/random-fixture" "${SHARED_DIR}/t7-archive"
    run_verify "${SHARED_DIR}/t7-archive" "overmindtech/cli" ".github/workflows/release.yml" no-gh || rc=$?
    rc=${rc:-0}
    assert_rc 99 "${rc}" "missing attestation (cosign)"
    unset rc
else
    echo "  SKIP: no published cosign binary for ${host_os}/${host_arch}"
fi

note "8/9 GH_TOKEN rejected (401) — must fall back to unauth and still verify (cosign path)"
# Reproduces the env0 runner case where a fine-grained PAT scoped only to the
# customer's own repos is in the environment as GH_TOKEN. The attestations
# endpoint returns 401 for the bad bearer; we must retry without auth.
if host_has_cosign; then
    cp "${SHARED_DIR}/overmind-archive" "${SHARED_DIR}/t8-archive"
    set +e
    PATH="${NO_GH_PATH}" \
        OS="${host_os}" \
        ARCH="${host_arch}" \
        GH_TOKEN="ghp_definitely_not_a_real_token_xxxxxxxxxxxxxxxxxxxx" \
        sh -c '. "$1"; verify_attestation "$2" "$3" "$4"' \
        _ "${EXTRACTED}" "${SHARED_DIR}/t8-archive" "overmindtech/cli" ".github/workflows/release.yml"
    rc=$?
    set -e
    assert_rc 0 "${rc}" "bad GH_TOKEN falls back to unauth and verifies"
    unset rc
else
    echo "  SKIP: no published cosign binary for ${host_os}/${host_arch}"
fi

note "9/9 unauth rate-limit (403, X-RateLimit-Remaining=0) — must surface body and retry once (cosign path)"
# Reproduces the customer-reported env0 failure: no GH_TOKEN set, env0's shared
# egress IP has exhausted GitHub's 60/hour unauthenticated REST budget, and the
# attestations endpoint returns HTTP 403 with rate-limit headers. The plugin
# must (a) sleep up to X-RateLimit-Reset and retry once, and (b) succeed when
# the retry returns 200.
#
# We install a curl wrapper on PATH that intercepts only attestations-API URLs
# (cosign release downloads etc. pass through to the real curl binary). The
# first intercepted call returns 403 with a 2-second X-RateLimit-Reset; the
# second intercepted call returns a 200 plus the real attestation bundle we
# pre-fetch once at setup. This exercises the full retry-then-verify path end
# to end without consuming GitHub's real rate-limit budget on every retry.
if host_has_cosign; then
    REAL_CURL=$(command -v curl)
    STUB_DIR=$(mktemp -d)
    STUB_COUNTER="${STUB_DIR}/counter"
    STUB_BUNDLE="${STUB_DIR}/bundle.json"
    echo 0 > "${STUB_COUNTER}"

    if command -v sha256sum >/dev/null 2>&1; then
        OVM_DIGEST=$(sha256sum "${SHARED_DIR}/overmind-archive" | awk '{print $1}')
    else
        OVM_DIGEST=$(shasum -a 256 "${SHARED_DIR}/overmind-archive" | awk '{print $1}')
    fi
    "${REAL_CURL}" -fsSL \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/overmindtech/cli/attestations/sha256:${OVM_DIGEST}" \
        -o "${STUB_BUNDLE}"

    cat > "${STUB_DIR}/curl" <<EOF
#!/bin/sh
set -eu
url=""
for arg in "\$@"; do
    case "\${arg}" in
        http*|https*) url="\${arg}" ;;
    esac
done
case "\${url}" in
    *api.github.com/repos/*/attestations/*) ;;
    *) exec "${REAL_CURL}" "\$@" ;;
esac
# From here on we know it's an attestations call; consume args to find -o/-D.
output_file=""
headers_file=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) shift; output_file="\$1"; shift ;;
        -D) shift; headers_file="\$1"; shift ;;
        -w) shift; shift ;;
        -H) shift; shift ;;
        -X) shift; shift ;;
        --data-binary) shift; shift ;;
        -*) shift ;;
        *) shift ;;
    esac
done
n=\$(cat "${STUB_COUNTER}")
echo \$((n + 1)) > "${STUB_COUNTER}"
if [ "\${n}" = "0" ]; then
    reset=\$(( \$(date +%s) + 2 ))
    if [ -n "\${headers_file}" ]; then
        {
            printf 'HTTP/2 403\\r\\n'
            printf 'x-ratelimit-limit: 60\\r\\n'
            printf 'x-ratelimit-remaining: 0\\r\\n'
            printf 'x-ratelimit-reset: %d\\r\\n' "\${reset}"
            printf 'content-type: application/json\\r\\n'
            printf '\\r\\n'
        } > "\${headers_file}"
    fi
    if [ -n "\${output_file}" ]; then
        printf '%s' '{"message":"API rate limit exceeded for 1.2.3.4. (synthetic test response)","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}' > "\${output_file}"
    fi
    printf '403'
    exit 0
fi
# Retry: serve the pre-fetched real bundle as a synthetic 200 response.
reset=\$(( \$(date +%s) + 3600 ))
if [ -n "\${headers_file}" ]; then
    {
        printf 'HTTP/2 200\\r\\n'
        printf 'x-ratelimit-limit: 60\\r\\n'
        printf 'x-ratelimit-remaining: 59\\r\\n'
        printf 'x-ratelimit-reset: %d\\r\\n' "\${reset}"
        printf 'content-type: application/json\\r\\n'
        printf '\\r\\n'
    } > "\${headers_file}"
fi
if [ -n "\${output_file}" ]; then
    cat "${STUB_BUNDLE}" > "\${output_file}"
fi
printf '200'
exit 0
EOF
    chmod +x "${STUB_DIR}/curl"

    cp "${SHARED_DIR}/overmind-archive" "${SHARED_DIR}/t9-archive"
    set +e
    PATH="${STUB_DIR}:${NO_GH_PATH}" \
        OS="${host_os}" \
        ARCH="${host_arch}" \
        env -u GH_TOKEN -u GITHUB_TOKEN \
        sh -c '. "$1"; verify_attestation "$2" "$3" "$4"' \
        _ "${EXTRACTED}" "${SHARED_DIR}/t9-archive" "overmindtech/cli" ".github/workflows/release.yml"
    rc=$?
    set -e
    attempts=$(cat "${STUB_COUNTER}")
    rm -rf "${STUB_DIR}"
    assert_rc 0 "${rc}" "unauth rate-limit retry succeeds on second attempt"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "${attempts}" = "2" ]; then
        pass "rate-limit stub was called exactly twice (1 fail + 1 retry)"
    else
        FAILED_NAMES="${FAILED_NAMES} rate-limit-stub-call-count"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  FAIL: rate-limit stub call count (expected 2, got %s)\n' "${attempts}"
    fi
    unset rc attempts
else
    echo "  SKIP: no published cosign binary for ${host_os}/${host_arch}"
fi

# ---------------------------------------------------------------------------
# Bonus: verify that on_failure=pass does NOT swallow rc=99. This wraps a
# guaranteed-failing call inside the same subshell pattern the script trailer
# uses and asserts that 99 propagates.
# ---------------------------------------------------------------------------
note "bonus: on_failure=pass cannot swallow rc=99"
cp "${SHARED_DIR}/overmind-archive" "${SHARED_DIR}/tb-archive"
# Use a guaranteed-failing call (wrong signer-workflow) and confirm that the
# same wrapper logic the script trailer uses propagates rc=99 instead of
# converting it to rc=0 the way it would for any other failure.
set +e
TB_ARCHIVE="${SHARED_DIR}/tb-archive" \
TB_REPO="overmindtech/cli" \
TB_WF=".github/workflows/notreal.yml" \
TB_HELPERS="${EXTRACTED}" \
PATH="${PATH}" OS="${host_os}" ARCH="${host_arch}" sh -c '
. "${TB_HELPERS}"
main_script() { verify_attestation "${TB_ARCHIVE}" "${TB_REPO}" "${TB_WF}"; }
( main_script )
rc=$?
if [ "${rc}" -eq "${ATTESTATION_FAIL_EXIT}" ]; then
    exit "${rc}"
elif [ "${rc}" -ne 0 ]; then
    # This is the line we are testing: any *other* failure becomes rc=0
    # under on_failure=pass. We assert that we DON''T reach here for rc=99.
    exit 0
fi
'
rc=$?
set -e
assert_rc 99 "${rc}" "on_failure=pass non-bypass"

# ---------------------------------------------------------------------------
echo
echo "============================================================"
printf 'Total: %d   Pass: %d   Fail: %d\n' "${TESTS_RUN}" "${TESTS_PASSED}" "${TESTS_FAILED}"
if [ "${TESTS_FAILED}" -gt 0 ]; then
    printf 'Failed:%s\n' "${FAILED_NAMES}"
    exit 1
fi
echo "All tests passed."
