name = "marianoguerra/llm"

version = "0.3.0"

readme = "README.md"

repository = "https://github.com/marianoguerra/llm-mb"

license = "Apache-2.0"

keywords = [ "llm", "ai", "anthropic", "openai", "gemini", "moonbit" ]

description = "A dialect-agnostic LLM IR, one wire mapping per provider protocol, a data-driven provider registry, and a transport a browser can implement"

// Every LIBRARY here except `wire` is target-neutral, and that is the point:
// a browser page lowers a context, picks a dialect and lifts a reply without
// a server involved. So the default target is the one that proves it. `wire`
// reads an environment and opens a socket and is native-only — `just check`
// covers both, and CI runs that rather than a bare `moon check`.

preferred_target = "wasm-gc"

import {
  "moonbitlang/async@0.21.2",
}

// `cmd/` is this repo's own tooling — a live smoke test against whichever
// providers the operator has keys for. It is native, it is not importable,
// and nobody installing this module can use it, so it does not ship.

options(
  exclude: [ "cmd" ],
)
