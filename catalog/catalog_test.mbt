///|
/// The invariant that used to need a guard test walking two arrays: a
/// provider's default has to be a model it offers. It cannot fail by
/// accident any more — the offer IS the row — but it can still fail by
/// typo, and a default nobody serves is a frontend that starts and then
/// 400s on its first turn.
test "catalog: every default is a model the provider lists" {
  let registry = @catalog.default_registry()
  for spec in registry.providers {
    assert_true(spec.models.length() > 0)
    assert_true(
      spec.models.search_by(m => m.id == spec.default_model) is Some(_),
    )
    // And the API it names has to exist, or nothing can be built for it.
    assert_true(registry.api(spec.api) is Some(_))
  }
}

///|
/// A label picks a dialect, and the dialect knows which model it is for.
/// This is the whole of what `dialect/pick` used to be, as a lookup.
test "catalog: a label resolves to the dialect and model it names" {
  let registry = @catalog.default_registry()
  let cases = [
    ("anthropic:claude-opus-5", "anthropic-messages", "claude-opus-5"),
    ("openai:gpt-5.6-sol", "openai-responses", "gpt-5.6-sol"),
    ("gemini:gemini-2.5-pro", "google-generative-ai", "gemini-2.5-pro"),
    ("openrouter:moonshotai/kimi-k3", "openrouter", "moonshotai/kimi-k3"),
    // The one provider on a protocol it does not own: Cerebras answers as
    // `openai-completions`, because that is what it speaks and it has no
    // logged inferences addressed to a name of its own.
    ("cerebras:gpt-oss-120b", "openai-completions", "gpt-oss-120b"),
    // No model: the provider's default, not an empty one.
    ("gemini", "google-generative-ai", "gemini-3.8-flash"),
  ]
  for case in cases {
    let (label, api, model) = case
    guard registry.dialect_of(label) is Some(dialect) else {
      fail("no dialect for \{label}")
    }
    assert_eq(dialect.id(), api)
    assert_eq(dialect.model(), model)
  }
  // A provider this build does not know is None, deliberately, rather than
  // defaulting into one that would lower for the wrong protocol.
  assert_true(registry.dialect_of("mistral:large") is None)
}

///|
/// An unlisted model still LOWERS — a page may have been offered one by a
/// relay whose table is newer than its own, and refusing would strand a
/// selector the person is already looking at.
test "catalog: an unlisted model lowers, on the provider's own API" {
  let registry = @catalog.default_registry()
  guard registry.dialect_of("anthropic:claude-opus-6") is Some(dialect) else {
    fail("an unlisted model should still lower")
  }
  assert_eq(dialect.id(), "anthropic-messages")
  assert_eq(dialect.model(), "claude-opus-6")
}

///|
/// Where each provider's credential goes. Three shapes, and gemini is the
/// reason `{model}` is a template rather than a closure: its key AND its
/// model are in the URL.
test "catalog: each auth style puts the key where that provider wants it" {
  let registry = @catalog.default_registry()
  guard registry.endpoint(
      provider="anthropic",
      model="claude-opus-5",
      key="sk-a",
    )
    is Ok((url, headers)) else {
    fail("anthropic should resolve")
  }
  assert_eq(url, "https://api.anthropic.com/v1/messages")
  assert_eq(headers.get("x-api-key"), Some("sk-a"))
  assert_eq(headers.get("anthropic-version"), Some("2023-06-01"))
  guard registry.endpoint(provider="openai", model="gpt-5.6-sol", key="sk-o")
    is Ok((url, headers)) else {
    fail("openai should resolve")
  }
  assert_eq(url, "https://api.openai.com/v1/responses")
  assert_eq(headers.get("authorization"), Some("Bearer sk-o"))
  guard registry.endpoint(provider="cerebras", model="gpt-oss-120b", key="sk-c")
    is Ok((url, headers)) else {
    fail("cerebras should resolve")
  }
  assert_eq(url, "https://api.cerebras.ai/v1/chat/completions")
  assert_eq(headers.get("authorization"), Some("Bearer sk-c"))
  guard registry.endpoint(provider="gemini", model="gemini-2.5-pro", key="sk-g")
    is Ok((url, headers)) else {
    fail("gemini should resolve")
  }
  assert_eq(
    url, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent?key=sk-g",
  )
  assert_true(headers.get("authorization") is None)
}

///|
/// An empty model resolves to the default; an unlisted one does NOT.
///
/// This is the one place the registry is strict, and the strictness is the
/// point: the name is interpolated into a URL, and the list is exactly what
/// `labels()` offered, so nothing a selector can pick is refused and nothing
/// else is believed.
test "catalog: endpoint serves what it lists, and says so when it does not" {
  let registry = @catalog.default_registry()
  guard registry.endpoint(provider="gemini", model="", key="k") is Ok((url, _)) else {
    fail("an empty model should take the default")
  }
  assert_true(url.contains("gemini-3.8-flash"))
  guard registry.endpoint(provider="gemini", model="gemini-9", key="k")
    is Err(why) else {
    fail("an unlisted model should be refused")
  }
  assert_true(why.contains("gemini-9"))
  assert_true(
    registry.endpoint(provider="mistral", model="large", key="k") is Err(_),
  )
}

///|
/// Adding a vendor is a value, not a code path — the property the whole
/// registry exists for. An OpenAI-compatible endpoint needs no new dialect:
/// it names the API that already exists.
test "catalog: a fifth provider is a struct literal" {
  let lmstudio : @llm.ProviderSpec = {
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
  }
  let registry = @catalog.default_registry().with_provider(lmstudio)
  guard registry.dialect_of("lmstudio:qwen3-coder") is Some(dialect) else {
    fail("the new provider should resolve")
  }
  assert_eq(dialect.id(), "openai-completions")
  guard registry.endpoint(provider="lmstudio", model="qwen3-coder", key="")
    is Ok((url, headers)) else {
    fail("the new provider should have an endpoint")
  }
  assert_eq(url, "http://localhost:1234/v1/chat/completions")
  assert_true(headers.get("authorization") is None)
  // And the four that were already there are untouched.
  assert_true(registry.dialect_of("anthropic:claude-sonnet-5") is Some(_))
}

///|
/// The selector's options, and that they round-trip: every label the
/// registry offers is one it can build a dialect for.
test "catalog: every label it offers is one it can resolve" {
  let registry = @catalog.default_registry()
  let labels = registry.labels()
  assert_true(labels.length() > 40)
  assert_eq(labels[0], "openai:gpt-6-astra")
  for label in labels {
    assert_true(registry.dialect_of(label) is Some(_))
  }
}

///|
/// The rows Cerebras ships rather than the ids: the two models disagree about
/// whether reasoning can be turned off, and that disagreement is the whole
/// reason they are rows. `permissive` would have said yes to both.
test "catalog: cerebras rows say which model can stop thinking" {
  let registry = @catalog.default_registry()
  guard registry.model_info(provider="cerebras", model="gpt-oss-120b")
    is Some(oss) else {
    fail("gpt-oss-120b should have a row")
  }
  // No `none` to clamp to, so the least it can do is `low`.
  assert_eq(oss.clamp_effort(Off), Some("low"))
  assert_eq(oss.context_window, 131_072)
  assert_eq(oss.max_output_tokens, Some(40_960))
  assert_true(!oss.accepts(ImageIn))
  guard registry.model_info(provider="cerebras", model="gemma-4-31b")
    is Some(gemma) else {
    fail("gemma-4-31b should have a row")
  }
  assert_eq(gemma.clamp_effort(Off), Some("none"))
  assert_true(gemma.accepts(ImageIn))
  // The third one is hyphenated where models.dev spells it `qwen3.8-27b` for
  // almost every other provider. `GET /v1/models` on Cerebras is the
  // authority for an id that goes into a request body, and it says this.
  guard registry.model_info(provider="cerebras", model="qwen-3.8-27b")
    is Some(qwen) else {
    fail("qwen-3.8-27b should have a row")
  }
  assert_eq(qwen.clamp_effort(Off), Some("none"))
  // Probed: all three reject the levels either side of Cerebras' four.
  assert_eq(qwen.clamp_effort(Minimal), Some("low"))
  assert_eq(qwen.clamp_effort(Max), Some("high"))
  assert_true(qwen.accepts(ImageIn))
  // The one row here nobody has published a price for.
  assert_true(qwen.cost is None)
}

///|
/// The whole wiring in one turn: the row Cerebras ships reaches the body a
/// dialect the REGISTRY built lowers. Every other test here checks one link —
/// this is the one that fails if `completions_api_spec` stops handing the
/// resolved row to the dialect, which is the only thing making the row matter.
test "catalog: a cerebras turn lowers with the effort its row allows" {
  let registry = @catalog.default_registry()
  guard registry.dialect_of("cerebras:gpt-oss-120b") is Some(dialect) else {
    fail("cerebras should resolve")
  }
  let ctx : @llm.LlmContext = {
    system: None,
    messages: [UserMsg(content=[UserText("hi")])],
    tools: [],
    // `Off` is the level this model does not have.
    params: { ..@llm.LlmParams::default(), effort: Some(Off), },
  }
  guard dialect.lower_context(ctx)
    is { "model": String(model), "reasoning_effort": String(effort), .. } else {
    fail("a cerebras body should carry a clamped effort")
  }
  assert_eq(model, "gpt-oss-120b")
  // Clamped up, because the row says `none` does not exist here.
  assert_eq(effort, "low")
  // And gemma, which does have it, is left alone.
  guard registry.dialect_of("cerebras:gemma-4-31b") is Some(gemma) else {
    fail("gemma should resolve")
  }
  guard gemma.lower_context(ctx) is { "reasoning_effort": String(off), .. } else {
    fail("gemma should carry an effort too")
  }
  assert_eq(off, "none")
}

///|
/// The escape hatch for everything the trim dropped, and for anything shipped
/// after this version: a caller adds the model itself and keeps every
/// predefined one. Worth a test because `endpoint` and `model_info` disagree
/// on purpose — `model_info` will lower for an unlisted model, `endpoint`
/// refuses it, and it is `endpoint` that decides whether an id is reachable.
test "catalog: a consumer adds a model the catalog never listed" {
  let base = @catalog.default_registry()
  // A model released after this build: unlisted, so refused at the one place
  // that matters, however happily `model_info` lowers for it.
  assert_true(
    base.model_info(provider="openrouter", model="deepseek/deepseek-v9")
    is Some(_),
  )
  assert_true(
    base.endpoint(provider="openrouter", model="deepseek/deepseek-v9", key="sk")
    is Err(_),
  )
  guard base.with_model(
      provider="openrouter",
      @llm.ModelInfo::permissive("deepseek/deepseek-v9"),
    )
    is Some(registry) else {
    fail("openrouter is a provider this registry has")
  }
  assert_true(
    registry.endpoint(
      provider="openrouter",
      model="deepseek/deepseek-v9",
      key="sk",
    )
    is Ok(_),
  )
  assert_true(registry.dialect_of("openrouter:deepseek/deepseek-v9") is Some(_))

  // And the predefined models are all still there, on this provider and the
  // others — adding one is not forking the catalog.
  assert_eq(registry.labels().length(), base.labels().length() + 1)
  assert_true(
    registry.endpoint(
      provider="openrouter",
      model="deepseek/deepseek-v4.1-flash",
      key="sk",
    )
    is Ok(_),
  )
  assert_true(registry.dialect_of("anthropic:claude-sonnet-5") is Some(_))
  assert_true(registry.dialect_of("openai:gpt-6-astra") is Some(_))
  // The provider keeps its place, where `with_provider` would move it last.
  assert_eq(registry.providers[base.providers.length() - 1].id, "openrouter")
  assert_eq(registry.providers.map(p => p.id), base.providers.map(p => p.id))
}

///|
/// Same id in, and the row replaces the permissive entry rather than
/// doubling it — how a caller corrects a model this catalog lists too
/// generously.
test "catalog: adding a listed model replaces its row in place" {
  let base = @catalog.default_registry()
  let row = { ..@llm.ModelInfo::permissive("x-ai/grok-4.6"), reasoning: false, }
  guard base.with_model(provider="openrouter", row) is Some(registry) else {
    fail("openrouter is a provider this registry has")
  }
  assert_eq(registry.labels().length(), base.labels().length())
  guard registry.model_info(provider="openrouter", model="x-ai/grok-4.6")
    is Some(info) else {
    fail("still listed")
  }
  assert_false(info.reasoning)
}

///|
test "catalog: with_model on a provider that is not there says so" {
  let base = @catalog.default_registry()
  assert_true(
    base.with_model(provider="opnrouter", @llm.ModelInfo::permissive("x"))
    is None,
  )
}
