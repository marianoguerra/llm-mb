// Every provider whose credential is in this environment, over the two
// smallest requests that still cross the whole path: lower a context, post
// it, feed the reply back through the stream decoder, and read what came
// out. Nothing here asserts a model said anything in particular — only that
// the shapes survived the round trip, which is the part this module owns.
//
// Providers with no key are SKIPPED, not failed. Which of them are
// configured is the operator's business; the point is to exercise what can
// be reached, and `@wire.configured` already answers exactly that question.

///|
/// The model each provider gets exercised on: the cheapest one that actually
/// does both cases, which is not the one its row defaults to.
///
/// A deliberate override of `LLM_*_MODEL` and of `default_model`: this
/// program exists to be run often and cost nothing, and a smoke test on
/// `claude-opus-5` is a smoke test nobody runs twice. A provider missing
/// from this table falls back to its own default, so an operator's sixth
/// vendor still gets exercised.
///
/// "Cheapest that works" and not "cheapest": `gpt-5-nano` was a third the
/// price of `gpt-5-mini` and answered the tool case in prose about a third of
/// the time, at every effort and output cap tried. A smoke test that fails
/// when nothing is broken is worse than useless — it teaches you to ignore
/// it — and the difference here is a hundredth of a cent.
///
/// EVERY ID HERE MUST BE ONE THE CATALOG LISTS. `model_for` falls back to the
/// provider's default when it is not, which is right for an operator's sixth
/// vendor and silent for a typo — and silence here costs money rather than a
/// failure. Trimming the catalog to two models per size group left this table
/// naming a `gpt-5-mini` and a `gemini-2.5-flash-lite` that were gone, and a
/// full run quietly moved onto gpt-5.6-sol at eight times the price. The test
/// below is what makes that loud.
fn smoke_model(provider : String) -> String? {
  match provider {
    "anthropic" => Some("claude-haiku-4-5")
    // Luna is the cheap lane of the 5.6 family and has a real `none`, so the
    // `Off` below is off rather than clamped onto a `minimal` that no longer
    // exists anywhere in this catalog.
    "openai" => Some("gpt-5.6-luna")
    "gemini" => Some("gemini-3.1-flash-lite")
    "openrouter" => Some("openai/gpt-5.4-mini")
    // Cerebras serves two, and this is the cheaper.
    "cerebras" => Some("gpt-oss-120b")
    _ => None
  }
}

///|
/// The model this run will actually use: the cheap one where the provider
/// still lists it, its own default otherwise.
///
/// The fallback is not defensive padding. `smoke_model` names ids that live in
/// another package, and `Registry::endpoint` refuses a model the provider
/// does not list — so a catalog that retires one should cost this run a
/// little more money, not the whole provider.
fn model_for(spec : @llm.ProviderSpec) -> String {
  guard smoke_model(spec.id) is Some(want) else { return spec.default_model }
  if spec.models.search_by(m => m.id == want) is Some(_) {
    want
  } else {
    spec.default_model
  }
}

///|
/// One tool, with one required argument, so a reply that calls it has
/// something to have got wrong.
fn ping_tool() -> @llm.ToolDecl {
  {
    name: "ping",
    description: "Answer a ping. Call this to reply.",
    input_schema: {
      "type": "object",
      "properties": { "value": { "type": "string" } },
      "required": ["value"],
    },
  }
}

///|
/// Ask for as little thought and as few tokens as the dial allows. `Off`
/// clamps to whatever the model's own row says is least — `minimal` on
/// gpt-5-mini, `low` on gpt-oss-120b — so this is "cheapest available"
/// rather than a level anyone has to have.
fn frugal(cap : Int) -> @llm.LlmParams {
  {
    ..@llm.LlmParams::default(),
    effort: Some(Off),
    max_output_tokens: Some(cap),
  }
}

///|
/// POST one lowered body and return the whole reply text.
///
/// The transport is in continuations, so the answer arrives in a callback
/// rather than as a return value. `with_task_group` is what turns that back
/// into a value: it does not return until the task `spawn` started has
/// finished, and by then the callback has written its cell.
async fn post(
  url : String,
  headers : Map[String, String],
  body : Json,
) -> Result[String, String] {
  let chunks = StringBuilder()
  let outcome : Ref[Result[String, String]] = { val: Err("no answer"), }
  @async.with_task_group(group => {
    let transport : @wire.HttpTransport = {
      url,
      headers,
      spawn: task => group.spawn_bg(task),
    }
    @llm.LlmTransport::send(
      transport,
      handle="smoke",
      target="smoke",
      body~,
      headers={},
      on_chunk=chunk => chunks.write_string(chunk),
      on_done=() => outcome.val = Ok(chunks.to_string()),
      on_error=err => outcome.val = Err(err),
    )
  })
  outcome.val
}

///|
/// Lower, post, and decode — through `stream_init`/`stream_feed`/
/// `stream_finish` rather than `lift_message`, because that is the path a
/// caller actually drives and the default `stream_finish` lifts anyway. One
/// round trip covers both.
async fn round_trip(
  dialect : &@llm.Dialect,
  url : String,
  headers : Map[String, String],
  ctx : @llm.LlmContext,
) -> Result[@llm.ContextMessage, String] {
  guard (post(url, headers, dialect.lower_context(ctx)) catch {
      err => return Err("transport: \{err}")
    })
    is Ok(text) else {
    return Err("transport: the call never happened")
  }
  // Parsed once here only to tell "the provider answered with an HTML error
  // page" apart from "the dialect could not read a reply it did parse". The
  // decoder below does its own reading; this is for the message.
  ignore(
    @json.parse(text) catch {
      _ => return Err("the reply was not JSON: \{clip(text)}")
    },
  )
  let state = dialect.stream_init()
  let (state, _) = dialect.stream_feed(state, chunk=text) catch {
    err => return Err("stream_feed: \{err}")
  }
  try dialect.stream_finish(state) catch {
    err => Err("stream_finish: \{err}")
  } noraise {
    msg => Ok(msg)
  }
}

///|
/// Enough of a long string to read, and no more — a provider's error page
/// can be a whole HTML document.
fn clip(text : String) -> String {
  let sb = StringBuilder()
  let mut taken = 0
  for c in text.iter() {
    if taken == 160 {
      sb.write_string("…")
      break
    }
    sb.write_char(c)
    taken += 1
  }
  sb.to_string()
}

///|
/// `StopReason` derives Debug and not Show, so a message that wants to name
/// one spells it out.
fn stop_name(stop : @llm.StopReason) -> String {
  match stop {
    EndTurn => "end_turn"
    MaxTokens => "max_tokens"
    ToolUse => "tool_use"
    Aborted => "aborted"
    Errored => "errored"
  }
}

///|
/// What a good answer looks like: an assistant turn that is not an error,
/// carrying whatever the case asked for.
fn verdict(
  msg : @llm.ContextMessage,
  want_tool~ : Bool,
) -> Result[String, String] {
  guard msg is AssistantMsg(content~, stop~, usage~, error~, ..) else {
    return Err("not an assistant turn")
  }
  if error is Some(why) {
    return Err("provider said: \{clip(why)}")
  }
  let spent = match usage {
    Some(u) => "in \{u.input} out \{u.output}"
    None => "no usage reported"
  }
  if want_tool {
    let mut called = None
    for block in content {
      if block is ToolCall(name~, arguments~, ..) {
        called = Some((name, arguments))
      }
    }
    guard called is Some((name, arguments)) else {
      return Err(
        "no tool call in the reply (stop=\{stop_name(stop)}, \{spent})",
      )
    }
    // The arguments crossed as a JSON *string* and came back parsed, which
    // is the quirk this case exists to watch.
    guard arguments is Object(_) else {
      return Err("tool arguments did not parse to an object")
    }
    return Ok("called \{name}, \{spent}")
  }
  let mut said = ""
  for block in content {
    if block is AssistantText(text~, ..) {
      said = said + text
    }
  }
  if said.trim().is_empty() {
    return Err("no text in the reply (stop=\{stop_name(stop)}, \{spent})")
  }
  Ok("said \{clip(said.trim().to_owned())}, \{spent}")
}

///|
/// A round trip and its verdict, which are two failures with one report
/// between them: a call that never landed and a reply that landed wrong both
/// come out as `Err` with something readable in it.
fn checked(
  outcome : Result[@llm.ContextMessage, String],
  want_tool~ : Bool,
) -> Result[String, String] {
  match outcome {
    Err(why) => Err(why)
    Ok(msg) => verdict(msg, want_tool~)
  }
}

///|
/// The two cases, run against one provider.
async fn exercise(
  registry : @llm.Registry,
  spec : @llm.ProviderSpec,
  key : String,
) -> Array[(String, Result[String, String])] {
  let model = model_for(spec)
  let out : Array[(String, Result[String, String])] = []
  guard registry.endpoint(provider=spec.id, model~, key~) is Ok((url, headers)) else {
    out.push(("setup", Err("no endpoint for \{spec.id}:\{model}")))
    return out
  }
  guard registry.dialect_of("\{spec.id}:\{model}") is Some(dialect) else {
    out.push(("setup", Err("no dialect for \{spec.id}:\{model}")))
    return out
  }
  // One turn, one word back. The whole plain path: system prompt, a user
  // turn, usage, and text.
  let plain : @llm.LlmContext = {
    system: Some("Answer in one word. Do not explain."),
    messages: [UserMsg(content=[UserText("Say pong.")])],
    tools: [],
    params: frugal(64),
  }
  out.push(
    ("text", checked(round_trip(dialect, url, headers, plain), want_tool=false)),
  )
  // The same turn with a tool on the table, which is the half of the mapping
  // the first case cannot reach.
  let tools : @llm.LlmContext = {
    system: Some("Use the ping tool. Do not answer in prose."),
    messages: [UserMsg(content=[UserText("Ping with the value \"pong\".")])],
    tools: [ping_tool()],
    params: frugal(256),
  }
  out.push(
    ("tools", checked(round_trip(dialect, url, headers, tools), want_tool=true)),
  )
  out
}

///|
/// A status for the shell, without a stack trace over the report.
///
/// MoonBit's core has no process-exit primitive, and `abort` prints a panic
/// dump after the last line — which, on a run where four cases failed, is
/// twenty lines of event-loop frames on top of the four that say why. libc's
/// own `exit` is reachable because this package is native by construction,
/// which is the one thing being an executable here buys.
extern "c" fn exit_process(code : Int) -> Unit = "exit"

///|
async fn main {
  let registry = @catalog.default_registry()
  let configured = @wire.configured(registry)
  let skipped : Array[String] = []
  for spec in registry.providers {
    if configured.search_by(p => p.0.id == spec.id) is None {
      skipped.push("\{spec.id} (\{spec.key_env})")
    }
  }
  if configured.is_empty() {
    println("No provider is configured. Set one of:")
    for spec in registry.providers {
      println("  \{spec.key_env}  — \{spec.name}")
    }
    return
  }
  println("Exercising \{configured.length()} configured provider(s).")
  if !skipped.is_empty() {
    println("Skipped, no key set: \{skipped.join(", ")}")
  }
  println("")
  let mut failed = 0
  for entry in configured {
    let (spec, key) = entry
    println("\{spec.name} — \{model_for(spec)}")
    for result in exercise(registry, spec, key) {
      let (case, outcome) = result
      match outcome {
        Ok(detail) => println("  ok    \{case}: \{detail}")
        Err(why) => {
          failed = failed + 1
          println("  FAIL  \{case}: \{why}")
        }
      }
    }
    println("")
  }
  if failed > 0 {
    println("\{failed} case(s) failed.")
    exit_process(1)
  }
  println("All cases passed.")
}
