// What a model can be asked for, as data. Bodies for the declarations in
// spec.mbt.

///|
pub fn ModelInfo::permissive(id : String) -> ModelInfo {
  {
    id,
    api: None,
    reasoning: true,
    thinking_levels: [
      (Off, "none"),
      (Minimal, "minimal"),
      (Low, "low"),
      (Medium, "medium"),
      (High, "high"),
      (XHigh, "xhigh"),
      (Max, "max"),
    ],
    supports_pro_mode: false,
    reasoning_contexts: [AutoContext, CurrentTurn, AllTurns],
    input: [TextIn, ImageIn],
    context_window: 0,
    max_output_tokens: None,
    cost: None,
  }
}

///|
pub fn ModelInfo::clamp_effort(
  self : ModelInfo,
  level : ThinkingLevel,
) -> String? {
  let mut above : (ThinkingLevel, String)? = None
  let mut below : (ThinkingLevel, String)? = None
  for pair in self.thinking_levels {
    if pair.0 == level {
      return Some(pair.1)
    } else if pair.0 > level {
      if above is Some(best) && best.0 <= pair.0 {
        continue
      }
      above = Some(pair)
    } else {
      if below is Some(best) && best.0 >= pair.0 {
        continue
      }
      below = Some(pair)
    }
  }
  match (above, below) {
    (Some(pair), _) => Some(pair.1)
    (None, Some(pair)) => Some(pair.1)
    (None, None) => None
  }
}

///|
pub fn ModelInfo::allows_context(
  self : ModelInfo,
  context : ReasoningContext,
) -> Bool {
  self.reasoning_contexts.contains(context)
}

///|
pub fn ModelInfo::accepts(self : ModelInfo, modality : Modality) -> Bool {
  self.input.contains(modality)
}
