#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
sources="$project_dir/Sources"
failed=0

fail() {
    echo "  ✗ $1"
    failed=1
}

# Matches in code, not in prose. Several of these rules are explained in the
# doc comment right above the thing they constrain — naming the banned API is
# how the comment says what it is protecting against — so a check that could
# not tell a comment from a call would make the code unable to explain
# itself.
code_matches() {
    grep -REn "$1" "$sources" 2>/dev/null \
        | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)" \
        || true
}

echo "Checking the privacy guarantee structurally…"

# 1. Exactly one target may open a socket.
#
# This is the guarantee itself, not a lint rule. Every other target in the
# package is incapable of making a request, so "nothing leaves this Mac" is a
# fact about the dependency graph rather than a claim about the code's
# intentions — and any edit that changes it fails here rather than in
# somebody's packet capture.
networking='URLSession|NWConnection|NWBrowser|CFSocket|CFStream|getaddrinfo|Network\.framework|URLRequest'
offenders="$(code_matches "$networking" | grep -v "^$sources/DocPrivacy/" || true)"
if [[ -n "$offenders" ]]; then
    fail "networking API outside DocPrivacy:"
    echo "$offenders" | sed 's|^|      |'
else
    echo "  ✓ only DocPrivacy links a networking API"
fi

# 2. The shared session carries the system's cookies, cache, and credentials.
#    Nothing here may use it.
if [[ -n "$(code_matches 'URLSession\.shared')" ]]; then
    fail "URLSession.shared is used somewhere in Sources"
else
    echo "  ✓ no use of URLSession.shared"
fi

# 3. Foundation Models ships two models in one framework, and one of them is
#    not on this machine. `PrivateCloudComputeLanguageModel` sends the prompt
#    — which here is the reader's document — to Apple's servers. It is one
#    identifier away from the one this app uses, so it is banned by name.
if [[ -n "$(code_matches 'PrivateCloudComputeLanguageModel')" ]]; then
    fail "Private Cloud Compute is used in Sources"
else
    echo "  ✓ no reference to Private Cloud Compute"
fi

# 4. The endpoint type is the only way to name an address, and it must stay
#    the only thing PrivateSession will accept.
if grep -Eq 'func (get|post|postLines)\(\s*$|_ endpoint: LoopbackEndpoint' \
    "$sources/DocPrivacy/PrivateSession.swift"; then
    echo "  ✓ PrivateSession takes nothing but a LoopbackEndpoint"
else
    fail "PrivateSession no longer requires a LoopbackEndpoint"
fi

# 5. An exported page that fetched anything would defeat the point of never
#    having uploaded it.
if grep -En 'https?://' "$sources/DocRender/HTMLExport.swift" \
    | grep -qvE "^[0-9]+:[[:space:]]*(//|\*)"; then
    fail "the HTML export contains a URL"
else
    echo "  ✓ exported pages are self-contained"
fi

if (( failed )); then
    echo "Privacy checks failed."
    exit 1
fi
echo "Privacy checks passed."
