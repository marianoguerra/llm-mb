# marianoguerra/llm

A dialect-agnostic LLM IR, one wire mapping per provider protocol, a registry
that makes a fifth provider a struct literal, and a transport a browser can
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
| `llm/catalog` | The four providers as data. Credential-free |
| `llm/wire` | Reading a key out of an environment, resolving an endpoint with it, and an HTTP transport. **The only native package here** |

Everything except `llm/wire` is target-neutral, so a browser page can lower a
context, choose a dialect and lift a reply with no server involved — the page
does both stages and a relay only forwards bytes, never learning which
provider is on the other end. `preferred_target` is `wasm-gc` so that stays
true by default; `just check` covers native too.

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

`{model}` in `endpoint` is substituted where a provider puts the model in the
URL instead of the body. `auth` is `BearerHeader | KeyHeader(name) |
KeyQuery(name) | NoAuth` — the credential itself is never in a `ProviderSpec`,
only the name of the variable holding it, which is what lets one compile into a
page.

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
