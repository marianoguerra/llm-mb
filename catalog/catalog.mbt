// The five providers this build ships. One row each, and a row is all a
// sixth would be — Cerebras is the proof, being exactly that and nothing
// more.

///|
/// Curated model ids as `ModelInfo`s, for a provider whose API has no probed
/// capability table. Permissive is the honest answer: nobody has sent these
/// models a `reasoning_effort` to see which ones they reject.
fn permissive_models(ids : Array[String]) -> Array[@llm.ModelInfo] {
  ids.map(@llm.ModelInfo::permissive)
}

///|
/// JSON in, JSON out — what every provider here wants on every call, and the
/// only header four of the five need beyond their credential.
fn json_headers() -> Map[String, String] {
  { "content-type": "application/json" }
}

///|
/// Cerebras' two public models, as rows rather than as ids.
///
/// They earn rows because they disagree about the one thing a row decides:
/// `gpt-oss-120b` has no `none` level — its reasoning cannot be turned off —
/// while `gemma-4-31b` has one. `permissive_models` would offer both every
/// level there is, and `clamp_effort` would hand `gpt-oss-120b` a `none` it
/// answers with a 400. With the rows, `Off` clamps UP to `low`, which is the
/// least the model can do rather than an error.
///
/// UNPROBED, in the sense openai/models.mbt means it: these figures are
/// models.dev's, by way of the catalog pi.dev generates from it, and nobody
/// has sent either model a level to watch it be rejected. Cerebras' own docs
/// are thinner and disagree about whether these reason at all.
fn cerebras_models() -> Array[@llm.ModelInfo] {
  [
    {
      id: "gpt-oss-120b",
      api: None,
      reasoning: true,
      thinking_levels: [(Low, "low"), (Medium, "medium"), (High, "high")],
      supports_pro_mode: false,
      // Neither knob exists on chat-completions, so the honest list is empty
      // rather than permissive's three.
      reasoning_contexts: [],
      input: [TextIn],
      context_window: 131_072,
      max_output_tokens: Some(40_960),
      cost: Some({
        input: 0.35,
        output: 0.75,
        cache_read: 0.0,
        cache_write: 0.0,
      }),
    },
    {
      id: "gemma-4-31b",
      api: None,
      reasoning: true,
      thinking_levels: [
        (Off, "none"),
        (Low, "low"),
        (Medium, "medium"),
        (High, "high"),
      ],
      supports_pro_mode: false,
      reasoning_contexts: [],
      input: [TextIn, ImageIn],
      context_window: 131_072,
      max_output_tokens: Some(40_960),
      cost: Some({
        input: 0.99,
        output: 1.49,
        cache_read: 0.0,
        cache_write: 0.0,
      }),
    },
  ]
}

///|
/// The first provider to take the door `openai-completions` was left open
/// for: an OpenAI-compatible vendor that needs no dialect, no ApiSpec and no
/// code path — only a row.
///
/// pi.dev models it the same way, and the two workarounds it carries for
/// Cerebras are ones this dialect never needed: it does not emit `store`, and
/// its system prompt is a `system` message and never a `developer` one.
///
/// The endpoint is the full path where pi keeps a base URL — an SDK appends
/// `/chat/completions` there, and here nothing does.
pub fn cerebras_provider() -> @llm.ProviderSpec {
  {
    id: "cerebras",
    name: "Cerebras",
    api: "openai-completions",
    endpoint: "https://api.cerebras.ai/v1/chat/completions",
    auth: BearerHeader,
    key_env: "CEREBRAS_API_KEY",
    model_env: "LLM_CEREBRAS_MODEL",
    default_model: "gpt-oss-120b",
    models: cerebras_models(),
    headers: json_headers(),
    telemetry_name: "cerebras",
    server_address: "api.cerebras.ai",
  }
}

///|
/// Responses, not completions. The gpt-5.6 family refuses function tools on
/// /v1/chat/completions unless reasoning is off, and every model listed here
/// works on this one. Completions is what the OpenAI-*compatible* vendors
/// speak; OpenAI itself is on its own API, the same split pi.dev draws.
pub fn openai_provider() -> @llm.ProviderSpec {
  {
    id: "openai",
    name: "OpenAI",
    api: "openai-responses",
    endpoint: "https://api.openai.com/v1/responses",
    auth: BearerHeader,
    key_env: "OPENAI_API_KEY",
    model_env: "LLM_OPENAI_MODEL",
    default_model: "gpt-5.6-sol",
    models: @openai.openai_models(),
    headers: json_headers(),
    telemetry_name: "openai",
    server_address: "api.openai.com",
  }
}

///|
pub fn anthropic_provider() -> @llm.ProviderSpec {
  {
    id: "anthropic",
    name: "Anthropic",
    api: "anthropic-messages",
    endpoint: "https://api.anthropic.com/v1/messages",
    auth: KeyHeader("x-api-key"),
    key_env: "ANTHROPIC_API_KEY",
    model_env: "LLM_ANTHROPIC_MODEL",
    default_model: "claude-sonnet-5",
    models: permissive_models([
      "claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-opus-4-8", "claude-opus-4-7",
      "claude-opus-4-6", "claude-opus-4-5", "claude-sonnet-4-6", "claude-sonnet-4-5",
      "claude-haiku-4-5", "claude-opus-4-1",
    ]),
    headers: {
      "content-type": "application/json",
      "anthropic-version": "2023-06-01",
    },
    telemetry_name: "anthropic",
    server_address: "api.anthropic.com",
  }
}

///|
/// The one endpoint with `{model}` in it, and the reason that substitution
/// exists at all: a target that drops the model reaches a different one than
/// the caller lowered for, and says so in Google's words rather than ours.
pub fn gemini_provider() -> @llm.ProviderSpec {
  {
    id: "gemini",
    name: "Google Gemini",
    api: "google-generative-ai",
    endpoint: "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
    auth: KeyQuery("key"),
    key_env: "GEMINI_API_KEY",
    model_env: "LLM_GEMINI_MODEL",
    default_model: "gemini-3.6-flash",
    models: permissive_models([
      // The two `-latest` entries are rolling aliases: they follow the newest
      // flash of their tier rather than pinning one, which is a different
      // choice from naming a version and so is offered beside it.
      "gemini-3.6-flash", "gemini-flash-latest", "gemini-3.5-flash", "gemini-3.5-flash-lite",
      "gemini-flash-lite-latest", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite",
      "gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite",
    ]),
    headers: json_headers(),
    telemetry_name: "gcp.gemini",
    server_address: "generativelanguage.googleapis.com",
  }
}

///|
pub fn openrouter_provider() -> @llm.ProviderSpec {
  {
    id: "openrouter",
    name: "OpenRouter",
    api: "openrouter",
    endpoint: "https://openrouter.ai/api/v1/chat/completions",
    auth: BearerHeader,
    key_env: "OPENROUTER_API_KEY",
    model_env: "LLM_OPENROUTER_MODEL",
    default_model: "openai/gpt-5.4-mini",
    models: permissive_models([
      "openai/gpt-5.4-mini", "moonshotai/kimi-k3", "moonshotai/kimi-k2.7-code", "moonshotai/kimi-k2.6",
      "qwen/qwen3.8-max", "qwen/qwen3.7-max", "qwen/qwen3.7-plus", "qwen/qwen3.7-flash",
      "qwen/qwen3-coder-next", "deepseek/deepseek-v4-pro", "deepseek/deepseek-v4-flash",
      "deepseek/deepseek-v4-flash-0731", "minimax/minimax-m3", "x-ai/grok-4.5", "z-ai/glm-5.2",
      "meta/muse-spark-1.2", "mistralai/mistral-medium-3-5", "thinkingmachines/inkling",
      "tencent/hy3",
    ]),
    headers: json_headers(),
    telemetry_name: "openrouter",
    server_address: "openrouter.ai",
  }
}

///|
/// Every API and provider this build knows. Provider order is the model
/// selector's order.
///
/// Five APIs for five providers, and no longer one each: `openai-completions`
/// is what Cerebras speaks, and what any other OpenAI-compatible vendor added
/// with `Registry::with_provider` will name — which is the whole point of the
/// registry being a value. Cerebras is that shape shipped rather than
/// described.
pub fn default_registry() -> @llm.Registry {
  @llm.Registry::of(
    [
      @openai.responses_api_spec(),
      @openai.completions_api_spec(),
      @anthropic.api_spec(),
      @gemini.api_spec(),
      @openrouter.api_spec(),
    ],
    [
      openai_provider(),
      cerebras_provider(),
      anthropic_provider(),
      gemini_provider(),
      openrouter_provider(),
    ],
  )
}
