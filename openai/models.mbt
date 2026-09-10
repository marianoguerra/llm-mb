// What each OpenAI model can be asked for. A table rather than branching
// inside `lower_context`: models differ in which reasoning levels exist at
// all — `max` arrived with the gpt-5.6 family, `minimal` went away after
// gpt-5, the o-series has neither — and asking for one a model lacks is a
// 400, not a downgrade. Keeping it as data is how pi.dev does it
// (`thinkingLevelMap`), and it means a new model is a row, not a code path.
//
// Every row below was probed against the API rather than read off a
// changelog (send the level, read whether it comes back `unsupported_value`;
// a rejection costs nothing). Two of the surprises are why: the gpt-5.6
// family has no `minimal` even though gpt-5 did, and `reasoning.context`
// accepts `all_turns` from gpt-5.4 onward but only `auto`/`current_turn`
// below it.
//
// The exceptions are marked UNPROBED: the `-pro`, `-nano` and `-codex` rows
// come from models.dev's catalog (what pi.dev generates its own table from)
// and nobody has sent them a request yet. They are here rather than left to
// the permissive fallback because the fallback offers every level to
// everything, and these are the models known to have the fewest — but the
// `contexts` and window figures in them are a reading, not a measurement.

///|
/// One row of the table below, as an `@llm.ModelInfo`.
///
/// The fields this fills in rather than taking: every model here accepts
/// images, and none of them has a price written down. The modality is a
/// reading and not a measurement — same standing as the UNPROBED rows — and
/// nothing reads it yet; `cost` stays None until somebody probes one.
fn row(
  id : String,
  reasoning~ : Bool,
  efforts~ : Array[(@llm.ThinkingLevel, String)],
  supports_pro_mode~ : Bool,
  contexts~ : Array[@llm.ReasoningContext],
  context_window~ : Int,
  max_output_tokens~ : Int?,
) -> @llm.ModelInfo {
  {
    id,
    api: None,
    reasoning,
    thinking_levels: efforts,
    supports_pro_mode,
    reasoning_contexts: contexts,
    input: [TextIn, ImageIn],
    context_window,
    max_output_tokens,
    cost: None,
  }
}

///|
/// Everything but `minimal`, which the gpt-5.6 family dropped, and `max`,
/// which it introduced.
fn efforts_5_6() -> Array[(@llm.ThinkingLevel, String)] {
  [
    (Off, "none"),
    (Low, "low"),
    (Medium, "medium"),
    (High, "high"),
    (XHigh, "xhigh"),
    (Max, "max"),
  ]
}

///|
/// gpt-5.2 through gpt-5.5: the same dial without `max`.
fn efforts_5_2() -> Array[(@llm.ThinkingLevel, String)] {
  [
    (Off, "none"),
    (Low, "low"),
    (Medium, "medium"),
    (High, "high"),
    (XHigh, "xhigh"),
  ]
}

///|
/// gpt-6-astra: the 5.6 dial minus `none`. Reasoning cannot be turned off,
/// so `Off` clamps UP to `low` the way it does for Cerebras' gpt-oss-120b.
/// UNPROBED (models.dev).
fn efforts_astra() -> Array[(@llm.ThinkingLevel, String)] {
  [
    (Low, "low"),
    (Medium, "medium"),
    (High, "high"),
    (XHigh, "xhigh"),
    (Max, "max"),
  ]
}

///|
/// The `-pro` variants: no way to turn reasoning off and no `low` — thinking
/// less is the thing you did not buy. UNPROBED (models.dev).
fn efforts_pro() -> Array[(@llm.ThinkingLevel, String)] {
  [(Medium, "medium"), (High, "high"), (XHigh, "xhigh")]
}

///|
/// gpt-5.1: no `xhigh` either.
fn efforts_5_1() -> Array[(@llm.ThinkingLevel, String)] {
  [(Off, "none"), (Low, "low"), (Medium, "medium"), (High, "high")]
}

///|
/// gpt-5: `minimal` instead of a way to turn reasoning off — so Off clamps
/// to `minimal` here, which is as close as this model gets.
fn efforts_5_0() -> Array[(@llm.ThinkingLevel, String)] {
  [(Minimal, "minimal"), (Low, "low"), (Medium, "medium"), (High, "high")]
}

///|
/// The o-series: three levels, no off switch.
fn efforts_o_series() -> Array[(@llm.ThinkingLevel, String)] {
  [(Low, "low"), (Medium, "medium"), (High, "high")]
}

///|
/// Persisted reasoning across turns, which arrived with gpt-5.4.
fn contexts_persisted() -> Array[@llm.ReasoningContext] {
  [AutoContext, CurrentTurn, AllTurns]
}

///|
/// Everything older takes `auto` and `current_turn` and rejects `all_turns`.
fn contexts_current_only() -> Array[@llm.ReasoningContext] {
  [AutoContext, CurrentTurn]
}

///|
/// The capabilities of `id`. An unrecognised model is treated permissively —
/// reasoning on, every level passed through under its portable name, no
/// output cap — so a model shipped after this table still works. The bet is
/// that a new model is a superset of an old one; a 400 naming the parameter
/// is a better failure than silently thinking less than it was asked to.
pub fn openai_model(id : String) -> @llm.ModelInfo {
  match id {
    // UNPROBED. The window follows the convention the `-pro` rows set: carry
    // the nearest probed sibling's figure rather than models.dev's, which
    // reads 1_050_000 for the whole gpt-5.6 family too and disagrees with
    // what those rows measured.
    "gpt-6-astra" =>
      row(
        id,
        reasoning=true,
        efforts=efforts_astra(),
        supports_pro_mode=true,
        contexts=contexts_persisted(),
        context_window=272_000,
        max_output_tokens=Some(128_000),
      )
    // "gpt-5.6" is the alias that routes to Sol.
    "gpt-5.6" | "gpt-5.6-sol" | "gpt-5.6-terra" | "gpt-5.6-luna" =>
      row(
        id,
        reasoning=true,
        efforts=efforts_5_6(),
        supports_pro_mode=true,
        contexts=contexts_persisted(),
        context_window=272_000,
        max_output_tokens=Some(128_000),
      )
    "gpt-5.5" | "gpt-5.4" | "gpt-5.4-mini" | "gpt-5.4-nano" =>
      row(
        id,
        reasoning=true,
        efforts=efforts_5_2(),
        supports_pro_mode=false,
        contexts=contexts_persisted(),
        context_window=if id == "gpt-5.5" { 272_000 } else { 400_000 },
        max_output_tokens=Some(128_000),
      )
    // UNPROBED. Same windows as the model each one is the pro of.
    "gpt-5.5-pro" | "gpt-5.4-pro" =>
      row(
        id,
        reasoning=true,
        efforts=efforts_pro(),
        supports_pro_mode=true,
        contexts=contexts_persisted(),
        context_window=if id == "gpt-5.5-pro" { 272_000 } else { 400_000 },
        max_output_tokens=Some(128_000),
      )
    // UNPROBED. Below gpt-5.4, so `all_turns` is not offered; spark is the
    // same model with a smaller window and a lower ceiling.
    "gpt-5.3-codex" | "gpt-5.3-codex-spark" =>
      row(
        id,
        reasoning=true,
        efforts=efforts_5_2(),
        supports_pro_mode=false,
        contexts=contexts_current_only(),
        context_window=if id == "gpt-5.3-codex-spark" {
          128_000
        } else {
          400_000
        },
        max_output_tokens=if id == "gpt-5.3-codex-spark" {
          Some(32_000)
        } else {
          Some(128_000)
        },
      )
    "gpt-5.2" =>
      row(
        id,
        reasoning=true,
        efforts=efforts_5_2(),
        supports_pro_mode=false,
        contexts=contexts_current_only(),
        context_window=400_000,
        max_output_tokens=Some(128_000),
      )
    // UNPROBED.
    "gpt-5.2-pro" =>
      row(
        id,
        reasoning=true,
        efforts=efforts_pro(),
        supports_pro_mode=true,
        contexts=contexts_current_only(),
        context_window=400_000,
        max_output_tokens=Some(128_000),
      )
    "gpt-5.1" =>
      row(
        id,
        reasoning=true,
        efforts=efforts_5_1(),
        supports_pro_mode=false,
        contexts=contexts_current_only(),
        context_window=400_000,
        max_output_tokens=Some(128_000),
      )
    "gpt-5" | "gpt-5-mini" | "gpt-5-nano" =>
      row(
        id,
        reasoning=true,
        efforts=efforts_5_0(),
        supports_pro_mode=false,
        contexts=contexts_current_only(),
        context_window=400_000,
        max_output_tokens=Some(128_000),
      )
    // UNPROBED, and the narrowest dial here: one level, `high`. Every other
    // request clamps onto it, which is what a model with nothing to trade
    // between speed and thought should do.
    "gpt-5-pro" =>
      row(
        id,
        reasoning=true,
        efforts=[(High, "high")],
        supports_pro_mode=true,
        contexts=contexts_current_only(),
        context_window=400_000,
        max_output_tokens=Some(272_000),
      )
    "o3" | "o4-mini" =>
      row(
        id,
        reasoning=true,
        efforts=efforts_o_series(),
        supports_pro_mode=false,
        contexts=contexts_current_only(),
        context_window=200_000,
        max_output_tokens=Some(100_000),
      )
    "gpt-4.1" | "gpt-4.1-mini" =>
      row(
        id,
        reasoning=false,
        efforts=[],
        supports_pro_mode=false,
        contexts=[],
        context_window=1_047_576,
        max_output_tokens=Some(32_768),
      )
    _ => @llm.ModelInfo::permissive(id)
  }
}

///|
/// Every model this table knows, in selector order.
///
/// The list and the capabilities are ONE array here, which is the point: they
/// used to be two — a list of ids in the provider table and a set of rows in
/// this one — kept in step by a test that walked the first looking for the
/// second. A model offered without a row is not a thing that can happen when
/// the offer IS the row.
pub fn openai_models() -> Array[@llm.ModelInfo] {
  [
    // xl, then lg, md, sm — the two newest of each, which is what the list is
    // now trimmed to. "gpt-5.6" is the alias that routes to Sol; it sits
    // outside that count because pinning the variant and following the alias
    // are different choices, not two different models.
    "gpt-6-astra", "gpt-5.5-pro", "gpt-5.6", "gpt-5.6-sol", "gpt-5.5", "gpt-5.6-terra",
    "gpt-5.3-codex", "gpt-5.6-luna", "gpt-5.4-mini",
  ].map(openai_model)
}

///|
/// The two OpenAI wire protocols as registry entries.
///
/// Responses is what OpenAI's own models are on; completions is what the
/// OpenAI-*compatible* vendors speak. Both read the same probed table, since
/// what a model can be asked for does not depend on which door you knock on.
pub fn responses_api_spec() -> @llm.ApiSpec {
  {
    id: "openai-responses",
    make: info => OpenAiResponsesDialect::make(model=info.id),
    caps: openai_model,
  }
}

///|
pub fn completions_api_spec() -> @llm.ApiSpec {
  {
    id: "openai-completions",
    make: info => OpenAiDialect::make(model=info.id, info~),
    caps: openai_model,
  }
}
