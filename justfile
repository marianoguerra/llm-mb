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

# Fail if the README's model tables and the catalog disagree (CI).
#
# The README lists every model the catalog ships, which is the question a
# reader arrives with and the last place anyone remembers to edit. A list that
# is wrong is worse than no list, and this is the same drift that let
# `smoke_model` keep naming a `gpt-5-mini` the catalog had dropped — silently,
# and at eight times the price per run.
#
# The catalog source is the truth and the README is checked against it, in
# both directions: a model added to `catalog.mbt` without a README row fails,
# and so does a README row naming a model that is no longer listed. OpenRouter
# ids carry a family prefix the README's table splits into its own column, so
# both sides are compared on the part after the slash — which is also why the
# count is 53 and not 54, `openai/gpt-5.4-mini` being OpenAI's own model
# served by somebody else.
readme-check:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 - <<'PY'
    import re, sys

    def quoted(text):
        # Comment lines carry example ids; the source of truth is code.
        code = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("//"))
        return re.findall(r'"([^"]+)"', code)

    cat = open("catalog/catalog.mbt").read()
    oa = open("openai/models.mbt").read()

    code = set(quoted(oa[oa.index("pub fn openai_models"):oa.index("].map(openai_model)")]))
    for pid in ('id: "anthropic"', 'id: "gemini"', 'id: "openrouter"'):
        i = cat.index(pid)
        j = cat.index("models: permissive_models([", i)
        code |= set(quoted(cat[j:cat.index("]),", j)]))
    code |= set(re.findall(r'id: "([^"]+)"',
                cat[cat.index("fn cerebras_models"):cat.index("pub fn cerebras_provider")]))

    readme = open("README.md").read()
    section = readme[readme.index("## Models"):readme.index("## What is NOT here")]
    # Table cells only: prose carries code spans that are not model ids.
    cells = [l for l in section.split("\n") if l.startswith("|")]
    listed = {t for l in cells for t in re.findall(r'`([^`]+)`', l)}
    # Aliases are named in prose rather than a table row, on purpose.
    listed |= set(re.findall(r'`([a-z0-9.\-]+)`', section[section.index("rolling aliases") - 400:]))

    # The family column ("qwen/") and the provider column are labels, not ids.
    labels = {"openai", "anthropic", "gemini", "cerebras", "openrouter"}
    listed = {x for x in listed if not x.endswith("/") and x not in labels}

    norm = lambda s: s.split("/", 1)[1] if "/" in s else s
    want = {norm(c) for c in code}
    have = {norm(x) for x in listed}

    missing = sorted(want - have)
    extra = sorted(have - want)
    if missing:
        print("readme-check: the catalog ships these and the README does not list them:")
        for m in missing: print("  " + m)
    if extra:
        print("readme-check: the README lists these and the catalog does not ship them:")
        for m in extra: print("  " + m)
    if missing or extra:
        sys.exit(1)
    print(f"readme-check: ok ({len(want)} models)")
    PY

# Fail if any importable package but `wire` has picked up a target
# restriction, or if `wire` has lost one (CI).
#
# The split is the module's headline property and it is one line per package
# to break. A `supported_targets = "native"` added to `openai` because
# something there wanted a socket would compile, pass, and quietly make this
# unusable from a browser.
#
# Executables are exempt, and the exemption is the rule stated exactly rather
# than widened: what the property protects is what a PAGE can import, and
# nothing imports an executable. `cmd/smoke` is native because it reads an
# environment and opens a socket; being unable to depend on it is precisely
# why that is harmless.
targets-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    for pkg in $(git ls-files '*moon.pkg' | sort); do
        dir=$(dirname "$pkg")
        if grep -qE 'pkgtype\(kind: *"executable"\)' "$pkg"; then
            continue
        fi
        if grep -qE '^[[:space:]]*supported_targets' "$pkg"; then
            [ "$dir" = "wire" ] || { echo "targets-check: $pkg restricts its target, is not wire, and is importable"; fail=1; }
        else
            [ "$dir" != "wire" ] || { echo "targets-check: wire lost supported_targets = native"; fail=1; }
        fi
    done
    [ "$fail" = 0 ] && echo "targets-check: ok"
    exit $fail

ci: fmt-check info-check spec-check targets-check readme-check check test

# Send real requests to every provider whose key is in the environment.
#
# NOT part of `ci`, and not a `_test.mbt`, because it costs money and needs
# credentials. It picks each provider's cheapest model and caps the reply at a
# few dozen tokens, so a full run is fractions of a cent; providers with no key
# set are skipped rather than failed.
smoke:
    moon run cmd/smoke --target native

# What `moon publish` would ship, without shipping it.
publish-dry: ci
    moon package --list

publish: ci
    moon publish
