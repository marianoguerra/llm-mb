// The openrouter dialect. OpenRouter exposes an OpenAI-compatible
// chat-completions API, so the wire mapping *is* the openai dialect; only
// the identity (and, in the transport, the endpoint + model routing prefix
// like "anthropic/claude-...") differ. We delegate to OpenAiDialect to keep
// exactly one chat-completions implementation.

///|
pub(all) struct OpenRouterDialect {
  inner : @openai.OpenAiDialect
} derive(Debug)

///|
pub fn OpenRouterDialect::make(
  model? : String,
  info? : @llm.ModelInfo,
) -> OpenRouterDialect {
  let model = model.unwrap_or("openai/gpt-5.4-mini")
  // The row travels too, so a caller holding a registry with real OpenRouter
  // rows gets those clamped against rather than OpenAI's table, which knows
  // none of these ids.
  {
    inner: match info {
      Some(info) => @openai.OpenAiDialect::make(model~, info~)
      None => @openai.OpenAiDialect::make(model~)
    },
  }
}

///|
pub impl @llm.Dialect for OpenRouterDialect with fn id(
  _self : OpenRouterDialect,
) -> String {
  "openrouter"
}

///|
pub impl @llm.Dialect for OpenRouterDialect with fn model(
  self : OpenRouterDialect,
) -> String {
  @llm.Dialect::model(self.inner)
}

///|
pub impl @llm.Dialect for OpenRouterDialect with fn lower_context(
  self : OpenRouterDialect,
  ctx : @llm.LlmContext,
) -> Json {
  @llm.Dialect::lower_context(self.inner, ctx)
}

///|
pub impl @llm.Dialect for OpenRouterDialect with fn lift_message(
  self : OpenRouterDialect,
  reply : Json,
) -> @llm.ContextMessage raise @llm.DialectError {
  @llm.Dialect::lift_message(self.inner, reply)
}

///|
/// This dialect as a registry entry.
///
/// Its own id rather than "openai-completions", though that is what it
/// speaks: the id is what a transcript records and what a relay resolves, so
/// changing it would re-address inferences already logged. Modelling
/// OpenRouter as the provider it is, over the API it borrows, is the right
/// end state and is its own decision to take.
pub fn api_spec() -> @llm.ApiSpec {
  {
    id: "openrouter",
    make: info => OpenRouterDialect::make(model=info.id, info~),
    caps: id => @llm.ModelInfo::permissive(id),
  }
}
