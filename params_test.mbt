///|
/// Configuration is read from the environment, where a typo is normal, so an
/// unrecognised value is None and the caller falls back rather than failing
/// a run over a spelling.
test "params: levels parse, and nonsense does not" {
  assert_true(@llm.ThinkingLevel::parse("xhigh") is Some(XHigh))
  assert_true(@llm.ThinkingLevel::parse("MAX") is Some(Max))
  // "none" and "off" are the same request: do not reason.
  assert_true(@llm.ThinkingLevel::parse("none") is Some(Off))
  assert_true(@llm.ThinkingLevel::parse("very hard") is None)
  assert_true(@llm.CacheRetention::parse("long") is Some(LongCache))
  assert_true(@llm.CacheRetention::parse("forever") is None)
  assert_true(@llm.ReasoningContext::parse("all_turns") is Some(AllTurns))
}

///|
/// The distinction the default exists to keep: asking for nothing is not
/// asking for `Off`. Off turns reasoning off, which is a decision no unset
/// variable should be making on a session's behalf.
test "params: the default asks for nothing" {
  let params = @llm.LlmParams::default()
  assert_true(params.effort is None)
  assert_true(params.max_output_tokens is None)
  assert_true(params.cache_key is None)
  assert_true(params.cache_retention is ShortCache)
  assert_false(params.pro_mode)
}
