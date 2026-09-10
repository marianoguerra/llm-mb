# marianoguerra/llm

A dialect-agnostic LLM IR, one wire mapping per provider protocol, a registry
that makes a sixth provider a struct literal, and a transport a browser can
implement.

Modelled on [pi.dev](https://pi.dev)'s `packages/ai`, which draws the same
three lines: an *api* is a wire protocol, a *provider* is a vendor with
credentials and a model catalog, and a collection routes between them.

```
moon add marianoguerra/llm
```

```moonbit
let registry = @catalog.default_registry()
guard registry.dialect_of("anthropic:claude-sonnet-5") is Some(dialect)
let body = dialect.lower_context(context)   // -> provider request JSON
let reply = dialect.lift_message(json)      // -> ContextMessage
```

Switching model mid-session is passing the same `LlmContext` to a different
`Dialect`. No session state migrates, because none exists.

## Packages

| Package | What it is |
|---|---|
| `llm` | `LlmContext` and the messages, blocks, usage and per-turn params it is made of; the `Dialect` trait; `StreamEvent`; `ModelInfo`; the `Registry`; `LlmTransport` and `RelayTransport` |
| `llm/anthropic` | `anthropic-messages` |
| `llm/openai` | `openai-responses` and `openai-completions`, plus a probed capability table |
| `llm/gemini` | `google-generative-ai` — the one whose endpoint carries the model |
| `llm/openrouter` | `openrouter`, which borrows the completions mapping |
| `llm/catalog` | The five providers as data — Cerebras among them, riding `openai-completions` with no dialect of its own. Credential-free |
| `llm/wire` | Reading a key out of an environment, resolving an endpoint with it, and an HTTP transport. **The only native library here** |
| `cmd/smoke` | A live check against every provider whose key is set. Native, and never run by `just ci` |

Every library here except `llm/wire` is target-neutral, so a browser page can lower a
context, choose a dialect and lift a reply with no server involved — the page
does both stages and a relay only forwards bytes, never learning which
provider is on the other end. `preferred_target` is `wasm-gc` so that stays
true by default; `just check` covers native too, and `just targets-check`
fails if any *importable* package but `wire` picks up a target restriction.
`cmd/smoke` is native and exempt, because nothing can import an executable.

## What is NOT here

No agent loop, no tool executor, no session store, no prompt templating. This
is the layer under those: what a turn's input is, how it becomes one
provider's JSON and back, and where the bytes go. It grew out of a hypermedia
agent that needed exactly this much and nothing above it.

## Adding a provider

If it speaks a protocol that already has an `ApiSpec`, it is a value:

```moonbit
let registry = @catalog.default_registry().with_provider({
  id: "lmstudio",
  name: "LM Studio",
  api: "openai-completions",
  endpoint: "http://localhost:1234/v1/chat/completions",
  auth: NoAuth,
  key_env: "",
  model_env: "",
  default_model: "qwen3-coder",
  models: [@llm.ModelInfo::permissive("qwen3-coder")],
  headers: { "content-type": "application/json" },
  telemetry_name: "lmstudio",
  server_address: "localhost",
})
```

`llm/catalog`'s `cerebras_provider()` is exactly this shape, shipped: Cerebras
speaks `openai-completions`, so it is a row with no dialect, no `ApiSpec` and
no code path — the same way pi.dev models it.

`{model}` in `endpoint` is substituted where a provider puts the model in the
URL instead of the body. `auth` is `BearerHeader | KeyHeader(name) |
KeyQuery(name) | NoAuth` — the credential itself is never in a `ProviderSpec`,
only the name of the variable holding it, which is what lets one compile into a
page.

## Adding a model

The catalog lists two models per size group per provider, which is a curation
and not a limit. A model it does not list — one shipped after this version,
or one the trim dropped — is a value too:

```moonbit
let registry = @catalog.default_registry()
  .with_model(provider="openrouter", @llm.ModelInfo::permissive("deepseek/deepseek-v4.1-flash"))
  .unwrap()
```

Every predefined model stays; this adds one beside them. `None` means no
provider has that id. Passing a model the provider already lists replaces that
row in place, which is how a caller narrows a `permissive` entry to what a
model actually accepts, and the provider keeps its position in the selector —
the same rule `with_provider` follows.

This matters because `Registry::endpoint` refuses a model the provider does
not list — `model_info` will happily lower a turn for an unknown id, on the
theory that a proxy's table may be newer than this one, but the id only
reaches a URL if it is listed.

## Adding a wire protocol

A new `Dialect` impl plus an `ApiSpec` naming it, handed to
`Registry::with_api`. Nothing in this package has a `match` over provider names
to edit.

```moonbit
pub fn api_spec() -> @llm.ApiSpec {
  { id: "my-api", make: info => MyDialect::make(model=info.id), caps: id => @llm.ModelInfo::permissive(id) }
}
```

The trait is six methods, three of which have defaults that buffer the body and
lift it whole — so a dialect is `id`, `lower_context` and `lift_message` until
it wants real streaming.

## Checking it against the real thing

`moon test` is offline and free — every dialect test lowers a context and lifts
a canned reply. To see whether the mapping still matches what the providers
actually do:

```
just smoke
```

It sends two real requests to **every provider whose key is in the
environment**, and skips the rest rather than failing them. `.env.example`
lists every variable the module reads, with what each one turns on:

```
cp .env.example .env   # then fill in the keys you have
set -a; . ./.env; set +a
``` Each provider gets
its cheapest model, `effort: Off` clamped onto whatever the model's row says is
least, and a reply capped at a few dozen tokens — a full five-provider run is
fractions of a cent.

The two cases are the two halves of a mapping: one plain turn (system prompt,
user turn, text and usage back) and one with a tool declared (tool lowering,
and a `ToolCall` lifted with its arguments parsed back out of the JSON string
they travel as). Both go through `stream_init`/`stream_feed`/`stream_finish`,
which is the path a real caller drives.

It lives in `cmd/smoke` as an executable rather than a `_test.mbt`, because
`moon test` runs everything it finds and this costs money and needs
credentials. `just ci` does not run it.

## Two things that look odd and are not

**`stream_feed` returns events, not a message.** Providers differ in how a
response is *framed* — event names, delta shapes, where usage and the stop
reason arrive — and decoding that anywhere but inside the dialect would mean
adding a provider in two places. `lift_message` is the non-streaming special
case of `stream_init ▸ stream_feed ▸ stream_finish`.

**`LlmTransport` is in continuations, not `async`.** A browser cannot have
async: `moonbitlang/async`'s event loop is unimplemented for wasm-gc, and an
async function cannot be called from the plain exported functions a page starts
from. A trait only a server could implement would not be a seam, so the native
side parks on a semaphore instead.
