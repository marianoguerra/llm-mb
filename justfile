# marianoguerra/llm

# Check every package on both targets.
#
# Two, not one: everything but `wire` has to compile to wasm-gc, because a
# browser page lowering and lifting for itself is the deployment this module
# exists to allow, and `moon check` on one target alone would let that rot
# without saying so. `wire` is native and is what the second pass is for.
check:
    moon check --deny-warn
    moon check --target native --deny-warn

# Run the tests on both targets, for the same reason.
test:
    moon test
    moon test --target native

fmt:
    moon fmt

fmt-check:
    moon fmt --check

# Regenerate the `pkg.generated.mbti` public-interface files.
info:
    moon info

# Fail if a checked-in interface file is stale (CI).
info-check: info
    git diff --exit-code -- '*.mbti'

# Fail if a package with a spec.mbt has public API the spec does not declare
# (CI).
#
# The convention is that `*/spec.mbt` declares a package's public surface with
# `#declaration_only` and the implementations live in sibling files. Only
# packages that HAVE a spec.mbt are checked — adding one is opting a package
# into the rule, which is the way round that lets it stay true.
spec-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    for spec in $(git ls-files '*spec.mbt' | sort); do
        pkg=$(dirname "$spec")
        mbti="$pkg/pkg.generated.mbti"
        [ -f "$mbti" ] || continue
        missing=""
        while read -r name; do
            [ -n "$name" ] || continue
            grep -qF "$name" "$spec" || missing="$missing $name"
        done < <(grep -oE '^pub fn [A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)?' "$mbti" \
                 | sed 's/^pub fn //' | sort -u)
        if [ -n "$missing" ]; then
            echo "spec-check: $spec does not declare:$missing"
            fail=1
        fi
    done
    [ "$fail" = 0 ] && echo "spec-check: ok"
    exit $fail

# Fail if anything but `wire` has picked up a target restriction, or if `wire`
# has lost one (CI).
#
# The split is the module's headline property and it is one line per package
# to break. A `supported_targets = "native"` added to `openai` because
# something there wanted a socket would compile, pass, and quietly make this
# unusable from a browser.
targets-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    for pkg in $(git ls-files '*moon.pkg' | sort); do
        dir=$(dirname "$pkg")
        if grep -qE '^[[:space:]]*supported_targets' "$pkg"; then
            [ "$dir" = "wire" ] || { echo "targets-check: $pkg restricts its target and is not wire"; fail=1; }
        else
            [ "$dir" != "wire" ] || { echo "targets-check: wire lost supported_targets = native"; fail=1; }
        fi
    done
    [ "$fail" = 0 ] && echo "targets-check: ok"
    exit $fail

ci: fmt-check info-check spec-check targets-check check test

# What `moon publish` would ship, without shipping it.
publish-dry: ci
    moon package --list

publish: ci
    moon publish
