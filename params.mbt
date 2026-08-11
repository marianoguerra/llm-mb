// The per-turn knobs: portable names here, provider spellings in the
// dialects.

///|
pub fn LlmParams::default() -> LlmParams {
  {
    effort: None,
    pro_mode: false,
    reasoning_context: None,
    reasoning_summary: false,
    max_output_tokens: None,
    cache_key: None,
    cache_retention: ShortCache,
  }
}

///|
pub fn ThinkingLevel::parse(s : String) -> ThinkingLevel? {
  match s.to_lower() {
    "off" | "none" => Some(Off)
    "minimal" => Some(Minimal)
    "low" => Some(Low)
    "medium" => Some(Medium)
    "high" => Some(High)
    "xhigh" => Some(XHigh)
    "max" => Some(Max)
    _ => None
  }
}

///|
pub fn CacheRetention::parse(s : String) -> CacheRetention? {
  match s.to_lower() {
    "none" | "off" => Some(NoCache)
    "short" | "default" => Some(ShortCache)
    "long" | "24h" => Some(LongCache)
    _ => None
  }
}

///|
pub fn ReasoningContext::parse(s : String) -> ReasoningContext? {
  match s.to_lower() {
    "auto" => Some(AutoContext)
    "current_turn" | "current" => Some(CurrentTurn)
    "all_turns" | "all" => Some(AllTurns)
    _ => None
  }
}
