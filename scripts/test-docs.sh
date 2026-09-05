#!/bin/bash
# Tests that the operator documentation still names things this repository has
# (SPEC.md §spec:operator-documentation).
#
# The documentation is written last, so everything it names already existed when
# it was written. The failure this guards is the NEXT change: a recipe or a
# script gets renamed, every caller is updated because the tools break loudly,
# and the documentation goes on naming the old one because nothing reads it.
# That drift is silent, and the reader who trips over it is the one who knows
# least about the repository.
#
# Three checks, all decidable from what the repository holds:
#
#   1. every `just <recipe>` named in a code span or code block is a real recipe
#   2. every repository path named in code resolves to a file that exists
#   3. every relative markdown link resolves to a file that exists
#
# It does NOT lint prose, check ports, or follow URLs. Ports and first-boot
# behaviour are checked by reading, because no test here can reach the machine.

# The fixtures below are markdown, and markdown's code spans are backticks. A
# backtick inside single quotes reads to the linter as a command substitution
# someone forgot to quote for; here it is the literal character under test.
# shellcheck disable=SC2016

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0

note_failure() {
    echo "NOT OK   - $*"
    failures=$(( failures + 1 ))
}

# The documentation, and the README that indexes it.
kantainer_doc_files() {
    local root="$1"
    ( cd "${root}" && ls README.md docs/*.md 2> /dev/null )
}

# Everything inside a code span or a fenced code block, one fragment per line.
#
# Code only, deliberately. Prose says things like "the fix is just to plug it
# in", and a check that read prose would have to guess whether that `just` names
# a recipe. Inside backticks there is no guessing left to do.
kantainer_code_text() {
    awk '
        /^[[:space:]]*```/ { fenced = !fenced; next }
        fenced { print; next }
        {
            line = $0
            while (match(line, /`[^`]+`/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$1"
}

# The names this repository answers to at its top level, from git rather than a
# list here - a list here would be the thing that goes stale.
#
# A token is only checked when it starts with one of these. That is what keeps
# the check off paths that belong to the installed MACHINE (/usr/lib/kantainer,
# /etc/containers) and off the operator's own files (kantainer.conf, which is
# git-ignored and must not exist here).
kantainer_tracked_top_level() {
    ( cd "${REPO_ROOT}" && git ls-files | cut -d / -f 1 | sort -u )
}

### 1. Recipes

# `just --show` resolves aliases and private recipes as well as the summary
# list, and it is just's own verdict rather than a parse of the Justfile.
check_recipes() {
    local root="$1" file recipe
    local -a named=()

    for file in $(kantainer_doc_files "${root}"); do
        while read -r recipe; do
            [[ -n "${recipe}" ]] || continue
            named+=("${file}:${recipe}")
        done < <(
            kantainer_code_text "${root}/${file}" |
                grep -oE '(^|[^[:alnum:]_.-])just +[a-z][a-z0-9_-]*' |
                sed -E 's/.*just +//' |
                sort -u
        )
    done

    local entry
    for entry in "${named[@]}"; do
        file="${entry%%:*}"
        recipe="${entry#*:}"
        if ! ( cd "${REPO_ROOT}" && just --show "${recipe}" ) > /dev/null 2>&1; then
            note_failure "${file} names \`just ${recipe}\`, which is not a recipe"
        fi
    done
}

### 2. Repository paths

check_paths() {
    local root="$1" file token
    local -a tops=()
    mapfile -t tops < <(kantainer_tracked_top_level)

    for file in $(kantainer_doc_files "${root}"); do
        while read -r token; do
            [[ -n "${token}" ]] || continue

            # Only tokens that start with something this repository has at its
            # top level. Everything else belongs to the machine or the operator.
            local top="${token%%/*}" known=""
            local candidate
            for candidate in "${tops[@]}"; do
                if [[ "${top}" == "${candidate}" ]]; then
                    known=1
                    break
                fi
            done
            [[ -n "${known}" ]] || continue

            # A trailing slash names the directory, not a file called "".
            local path="${token%/}"

            if [[ "${path}" == *'*'* ]]; then
                # A glob has to match something. `butane/*.tmpl` is a real claim
                # about this repository and can go stale like any other.
                if ! compgen -G "${REPO_ROOT}/${path}" > /dev/null; then
                    note_failure "${file} names \`${token}\`, which matches nothing"
                fi
            elif [[ ! -e "${REPO_ROOT}/${path}" ]]; then
                note_failure "${file} names \`${token}\`, which does not exist"
            fi
        done < <(
            kantainer_code_text "${root}/${file}" |
                grep -oE '[A-Za-z_.][A-Za-z0-9_.*-]*(/[A-Za-z0-9_.*-]+)*/?' |
                sort -u
        )
    done
}

### 3. Relative links

check_links() {
    local root="$1" file target resolved
    for file in $(kantainer_doc_files "${root}"); do
        while read -r target; do
            [[ -n "${target}" ]] || continue
            # Anchors are resolved by the reader's browser, not by us.
            target="${target%%#*}"
            [[ -n "${target}" ]] || continue

            resolved="$(cd "${root}/$(dirname "${file}")" && realpath -m "${target}")"
            [[ -e "${resolved}" ]] ||
                note_failure "${file} links to ${target}, which does not exist"
        done < <(
            grep -oE '\]\([^)]+\)' "${root}/${file}" |
                sed -E 's/^\]\(//; s/\)$//' |
                grep -vE '^[a-z]+:' |
                sort -u
        )
    done
}

### The repository as it stands

check_recipes "${REPO_ROOT}"
check_paths "${REPO_ROOT}"
check_links "${REPO_ROOT}"

if [[ "${failures}" -eq 0 ]]; then
    echo "ok       - the documentation names only things this repository has"
fi

### The checks themselves
#
# A check that cannot fail is worse than no check, and every one of these is a
# grep that a small change to the extraction would quietly turn into a no-op.
# So each is run once against a document built to break it.

expect_caught() {
    local name="$1" doc="$2" want="$3"
    local tmp before=0 caught

    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' RETURN
    mkdir -p "${tmp}/docs"
    printf '%s\n' "${doc}" > "${tmp}/docs/scratch.md"
    : > "${tmp}/README.md"

    before="${failures}"
    caught="$( check_recipes "${tmp}"; check_paths "${tmp}"; check_links "${tmp}" )"
    failures="${before}"

    if grep -q "${want}" <<< "${caught}"; then
        echo "ok       - ${name}"
    else
        note_failure "${name} (nothing reported ${want})"
    fi
}

expect_caught "a recipe that does not exist is caught" \
    'Run `just definitely-not-a-recipe` to do the thing.' \
    'not a recipe'

expect_caught "a renamed script is caught" \
    'The rule lives in `scripts/definitely-not-a-script.sh`.' \
    'does not exist'

expect_caught "a glob that matches nothing is caught" \
    'The templates are `butane/*.definitely-not-an-extension`.' \
    'matches nothing'

expect_caught "a broken link is caught" \
    'See [the thing](definitely-not-a-file.md).' \
    'does not exist'

# Prose is not code: this must NOT be read as a recipe called "to".
expect_caught "prose outside backticks is not read as a recipe" \
    'The fix is just to plug it in. But `just definitely-not-a-recipe` is not.' \
    'names `just definitely-not-a-recipe`'

if [[ "${failures}" -gt 0 ]]; then
    echo
    echo "${failures} documentation reference(s) no longer match this repository."
    echo "Fix the documentation, not the reader."
    exit 1
fi

echo
echo "the operator documentation matches the repository"
