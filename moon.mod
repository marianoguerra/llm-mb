name = "marianoguerra/llm"

version = "0.1.3"

readme = "README.md"

repository = "https://github.com/marianoguerra/llm-mb"

license = "Apache-2.0"

keywords = [ "llm", "ai", "anthropic", "openai", "gemini", "moonbit" ]

description = "A dialect-agnostic LLM IR, one wire mapping per provider protocol, a data-driven provider registry, and a transport a browser can implement"

// Every package here except `wire` is target-neutral, and that is the point:
// a browser page lowers a context, picks a dialect and lifts a reply without
// a server involved. So the default target is the one that proves it. `wire`
// reads an environment and opens a socket and is native-only — `just check`
// covers both, and CI runs that rather than a bare `moon check`.

preferred_target = "wasm-gc"

import {
  "moonbitlang/async@0.21.0",
  "moonbitlang/x@0.4.46",
}
