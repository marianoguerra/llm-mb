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
    // No model: the provider's default, not an empty one.
    ("gemini", "google-generative-ai", "gemini-3.6-flash"),
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
  assert_true(url.contains("gemini-3.6-flash"))
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
  assert_eq(labels[0], "openai:gpt-5.6")
  for label in labels {
    assert_true(registry.dialect_of(label) is Some(_))
  }
}
