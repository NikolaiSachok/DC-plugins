#!/usr/bin/env bash
#
# Generic pre-publish safety gate.
#
# This is the PUBLIC, generic layer: it looks for secrets, private absolute
# paths, and OS cruft that should never land in a public repo. It deliberately
# does NOT enumerate any business/domain terms — a checker that lists sensitive
# words would itself leak them. Domain-specific auditing (if any) belongs in a
# private gate run before push, never here.
#
# Runs in CI and can be wired as a pre-commit hook (see CONTRIBUTING.md).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

self="scripts/leak-guard.sh"
fail=0

scan() { # <regex> <human description>
    local hits
    hits=$(grep -rInE "$1" . \
        --binary-files=without-match \
        --exclude-dir=.git --exclude-dir=build 2>/dev/null \
        | grep -v "$self")
    if [ -n "$hits" ]; then
        printf '✗ %s\n%s\n\n' "$2" "$hits"
        fail=1
    fi
}

scan '/Users/[A-Za-z0-9._-]+/'                 'Absolute macOS home path — use $HOME or ~'
scan '/home/[A-Za-z0-9._-]+/'                  'Absolute Linux home path — use $HOME or ~'
scan '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}'  'GitHub OAuth/personal token'
scan 'github_pat_[A-Za-z0-9_]{20,}'            'GitHub fine-grained PAT'
scan 'AKIA[0-9A-Z]{16}'                        'AWS access key id'
scan 'xox[baprs]-[A-Za-z0-9-]{10,}'            'Slack token'
scan 'sk-[A-Za-z0-9]{20,}'                     'OpenAI-style secret key'
scan -- '-----BEGIN [A-Z ]*PRIVATE KEY-----'   'Private key block'

if find . -name .DS_Store -not -path './.git/*' | grep -q .; then
    echo "✗ .DS_Store committed"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "leak-guard: clean ✓"
else
    echo "leak-guard: FINDINGS above — fix before committing/publishing." >&2
fi
exit "$fail"
