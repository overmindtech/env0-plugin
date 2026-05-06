#!/bin/sh
# Refresh the COSIGN_SHA256_* pins in env0.plugin.yaml to match the cosign
# version currently set in COSIGN_VERSION. Used by Renovate's postUpgradeTasks
# after a cosign version bump, and runnable manually:
#
#     sh scripts/update-cosign-pins.sh
#
# Requires: curl, awk, sed. Reads cosign_checksums.txt published with each
# cosign release.
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PLUGIN="${REPO_ROOT}/env0.plugin.yaml"

if [ ! -f "${PLUGIN}" ]; then
    echo "error: ${PLUGIN} not found" >&2
    exit 1
fi

VERSION=$(awk -F'"' '/^[[:space:]]*COSIGN_VERSION=/{print $2; exit}' "${PLUGIN}")
if [ -z "${VERSION}" ]; then
    echo "error: COSIGN_VERSION not found in ${PLUGIN}" >&2
    exit 1
fi

CHECKSUMS_URL="https://github.com/sigstore/cosign/releases/download/${VERSION}/cosign_checksums.txt"
echo "Fetching checksums from ${CHECKSUMS_URL}..."
CHECKSUMS=$(curl -fsSL "${CHECKSUMS_URL}")

# extract <sha> for the cosign-<asset> filename and update the matching
# COSIGN_SHA256_<plat>="..." line in the YAML in-place.
update_pin() {
    plat="$1"
    asset="$2"
    sha=$(printf '%s\n' "${CHECKSUMS}" | awk -v a="${asset}" '$2==a{print $1; exit}')
    if [ -z "${sha}" ]; then
        echo "error: ${asset} not found in cosign ${VERSION} checksums" >&2
        exit 1
    fi
    echo "  ${plat} -> ${sha}"
    # replace the value while preserving leading whitespace and the var name.
    # use a tmp file so awk -i inplace isn't required (BSD/GNU portable).
    awk -v plat="${plat}" -v sha="${sha}" '
        {
            pat = "^([[:space:]]*COSIGN_SHA256_" plat "=)\"[^\"]*\"(.*)$"
            if (match($0, pat)) {
                # rebuild line with new SHA
                # split into prefix and suffix manually since match()/regex
                # replacement varies between awk implementations.
                printf("%sCOSIGN_SHA256_%s=\"%s\"\n", _leading_ws($0), plat, sha)
            } else {
                print
            }
        }
        function _leading_ws(line,    i, c) {
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c != " " && c != "\t") return substr(line, 1, i - 1)
            }
            return line
        }
    ' "${PLUGIN}" > "${PLUGIN}.tmp"
    mv "${PLUGIN}.tmp" "${PLUGIN}"
}

update_pin linux_amd64    cosign-linux-amd64
update_pin linux_arm64    cosign-linux-arm64
update_pin darwin_amd64   cosign-darwin-amd64
update_pin darwin_arm64   cosign-darwin-arm64
update_pin windows_amd64  cosign-windows-amd64.exe

echo "✓ Updated COSIGN_SHA256_* pins in ${PLUGIN} to match ${VERSION}"
