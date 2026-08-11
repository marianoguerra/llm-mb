// The anthropic-messages dialect: LlmContext <-> Anthropic Messages API
// JSON (system / messages with text|thinking|tool_use|tool_result blocks /
// tools / stop_reason / usage).

///|
pub(all) struct AnthropicDialect {
  model : String
  max_tokens : Int
} derive(Debug)

///|
#declaration_only
pub fn AnthropicDialect::make(
  model? : String,
  max_tokens? : Int,
) -> AnthropicDialect {
  ...
}

// `impl @llm.Dialect for AnthropicDialect` (id / lower_context /
// lift_message) is provided in anthropic.mbt — the `#declaration_only`
// attribute does not apply to trait impls.

///|
/// This dialect as a registry entry: how to build one for a model, and what
/// to assume about a model nobody wrote a row for.
#declaration_only
pub fn api_spec() -> @llm.ApiSpec {
  ...
}
