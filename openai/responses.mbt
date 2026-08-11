// The openai-responses dialect: LlmContext <-> OpenAI Responses JSON. This
// is the API OpenAI's own models are on — the completions dialect next door
// is for the OpenAI-*compatible* vendors (Groq, DeepSeek, Together, and
// OpenRouter's own dialect), which is the same split pi.dev draws.
//
// It is not a nicety. The gpt-5.6 family refuses function tools on
// /v1/chat/completions unless reasoning is turned off — "Function tools with
// reasoning_effort are not supported ... use /v1/responses or set
// reasoning_effort to 'none'" — so on completions those models are either
// broken or not reasoning.
//
// The per-turn knobs arrive on the context (@llm.LlmParams) and are
// mapped here against models.mbt: reasoning effort/mode/context, the output
// cap, and the prompt cache key. What this model cannot do is dropped rather
// than sent — the same rule as a signature the dialect cannot replay.
//
// Quirks kept inside this impl: the conversation is a flat `input` list of
// ITEMS rather than messages (an assistant turn with a reasoning block, a
// text block and two tool calls is four items, not one), user text is
// `input_text` while assistant text is `output_text`, tool arguments travel
// as a JSON *string*, a tool result is a `function_call_output` item keyed
// by `call_id`, and the system prompt is the top-level `instructions`.

///|
pub(all) struct OpenAiResponsesDialect {
  model : String
} derive(Debug)

///|
pub fn OpenAiResponsesDialect::make(model? : String) -> OpenAiResponsesDialect {
  { model: model.unwrap_or("gpt-5.6-sol") }
}

///|
pub impl @llm.Dialect for OpenAiResponsesDialect with fn id(
  _self : OpenAiResponsesDialect,
) -> String {
  "openai-responses"
}

///|
pub impl @llm.Dialect for OpenAiResponsesDialect with fn model(
  self : OpenAiResponsesDialect,
) -> String {
  self.model
}

///|
/// A user turn's content. Unlike completions this API has no plain-string
/// shorthand on the way in: every part is typed, and an image is a data URI
/// under `input_image` rather than `image_url`'s nested object.
fn responses_user_content(blocks : Array[@llm.UserBlock]) -> Json {
  Json::array(
    blocks.map(block => {
      match block {
        UserText(text) => { "type": "input_text", "text": Json::string(text) }
        UserImage(media_type~, data~) =>
          {
            "type": "input_image",
            "detail": "auto",
            "image_url": Json::string(
              "data:\{media_type};base64,\{@base64.encode(data[:])}",
            ),
          }
      }
    }),
  )
}

///|
/// What an assistant message item carries besides its text: its item id, and
/// `phase` — the field the 5.x-era models added, which OpenAI documents as
/// "preserve and resend on all assistant messages", dropping it degrades the
/// answer. Neither belongs in the IR, since no other provider has them, so
/// they ride in the block's `signature` exactly like a provider's proof
/// does. `v` is there so a later shape can be told apart from this one.
fn message_meta(item : Json) -> String? {
  let meta : Map[String, Json] = Map([])
  if item is { "id": String(id), .. } {
    meta["id"] = Json::string(id)
  }
  if item is { "phase": String(phase), .. } {
    meta["phase"] = Json::string(phase)
  }
  if meta.is_empty() {
    return None
  }
  meta["v"] = Json::number(1)
  Some(Json::object(meta).stringify())
}

///|
/// The wire name of a persisted-reasoning setting (gpt-5.6 and later).
fn reasoning_context_name(context : @llm.ReasoningContext) -> String {
  match context {
    AutoContext => "auto"
    CurrentTurn => "current_turn"
    AllTurns => "all_turns"
  }
}

///|
/// A prompt cache key is capped at 64 characters, counted in codepoints —
/// cutting bytes could split one in half and hand the API a broken string.
fn clamp_cache_key(key : String) -> String {
  let sb = StringBuilder()
  let mut taken = 0
  for c in key.iter() {
    if taken == 64 {
      break
    }
    sb.write_char(c)
    taken += 1
  }
  sb.to_string()
}

///|
pub impl @llm.Dialect for OpenAiResponsesDialect with fn lower_context(
  self : OpenAiResponsesDialect,
  ctx : @llm.LlmContext,
) -> Json {
  let model_info = openai_model(self.model)
  let params = ctx.params
  let input : Array[Json] = []
  for msg in ctx.messages {
    match msg {
      UserMsg(content~) =>
        input.push({
          "role": "user",
          "content": responses_user_content(content),
        })
      AssistantMsg(content~, model~, ..) => {
        // A reasoning item is sealed to the model that produced it, so a turn
        // replayed after a model switch drops it rather than handing one
        // model another's chain of thought (pi's isDifferentModel guard).
        let same_model = model == self.model
        for block in content {
          match block {
            AssistantText(text~, signature~) => {
              let item : Map[String, Json] = {
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [
                  {
                    "type": "output_text",
                    "text": Json::string(text),
                    "annotations": [],
                  },
                ],
              }
              // Same model only, for the same reason a reasoning item is:
              // the id was handed out by one model and OpenAI validates the
              // ids it gave, and a phase describes how *that* model was
              // working through the turn.
              if same_model && signature is Some(s) {
                let meta = @json.parse(s) catch { _ => Json::null() }
                if meta is { "id": String(id), .. } {
                  item["id"] = Json::string(id)
                }
                if meta is { "phase": String(phase), .. } {
                  item["phase"] = Json::string(phase)
                }
              }
              input.push(Json::object(item))
            }
            // The whole reasoning item, verbatim — its `encrypted_content` is
            // the model's chain across a tool call, and it is opaque, so the
            // signature IS the item rather than something built from the
            // summary text beside it. A block with no signature has nothing
            // replayable and is dropped: the summary alone is not the chain.
            Thinking(signature~, ..) =>
              if same_model && signature is Some(s) {
                let item = @json.parse(s) catch { _ => Json::null() }
                if item is Object(_) {
                  input.push(item)
                }
              }
            ToolCall(id~, name~, arguments~, ..) =>
              input.push({
                "type": "function_call",
                "call_id": Json::string(id),
                "name": Json::string(name),
                "arguments": Json::string(arguments.stringify()),
              })
          }
        }
      }
      ToolResultMsg(tool_call_id~, content~, ..) =>
        input.push({
          "type": "function_call_output",
          "call_id": Json::string(tool_call_id),
          "output": Json::string(@llm.user_text(content)),
        })
    }
  }
  let body : Map[String, Json] = {
    "model": Json::string(self.model),
    "input": Json::array(input),
    // Flat, unlike completions' {"type":"function","function":{...}} nesting,
    // and the schema is plain JSON Schema.
    "tools": Json::array(
      ctx.tools.map(tool => {
        (
          {
            "type": "function",
            "name": Json::string(tool.name),
            "description": Json::string(tool.description),
            "parameters": tool.input_schema,
          } : Json)
      }),
    ),
    // The log is the conversation, not a `previous_response_id` on OpenAI's
    // side: every turn ships the whole context, which is what makes switching
    // models mid-session work. `store: false` says so.
    "store": Json::boolean(false),
  }
  if ctx.system is Some(system) {
    body["instructions"] = Json::string(system)
  }
  // How hard to think. Asked for nothing means say nothing: the model's own
  // default applies, which is not the same as asking for `none` — that turns
  // reasoning off, and on this family it also takes function tools with it.
  // A level this model does not have is clamped, never sent.
  let effort = if model_info.reasoning && params.effort is Some(level) {
    model_info.clamp_effort(level)
  } else {
    None
  }
  if effort is Some(name) {
    let reasoning : Map[String, Json] = { "effort": Json::string(name) }
    // The summary is the only readable part; the chain replays either way,
    // because what replays is the opaque item and not the summary.
    if params.reasoning_summary {
      reasoning["summary"] = Json::string("auto")
    }
    if params.pro_mode && model_info.supports_pro_mode {
      reasoning["mode"] = Json::string("pro")
    }
    if params.reasoning_context is Some(context) &&
      model_info.allows_context(context) {
      reasoning["context"] = Json::string(reasoning_context_name(context))
    }
    body["reasoning"] = Json::object(reasoning)
  }
  // Asking for the encrypted reasoning is what makes replaying it possible
  // at all — without it the item comes back with nothing inside to replay.
  // Pointless where there will be no chain, so it is not asked for there.
  if model_info.reasoning && !(effort is Some("none")) {
    body["include"] = ["reasoning.encrypted_content"]
  }
  if params.max_output_tokens is Some(want) {
    let capped = match model_info.max_output_tokens {
      Some(cap) => if want < cap { want } else { cap }
      None => want
    }
    // The API refuses a cap under 16, and a number that small is a mistake
    // rather than an intent, so it is raised instead of rejected.
    body["max_output_tokens"] = Json::number(
      (if capped < 16 { 16 } else { capped }).to_double(),
    )
  }
  // Explicit prompt caching: a stable key is what lets the provider find the
  // prefix it cached for this conversation, and every turn here ships the
  // whole log, so the prefix is exactly what grows.
  if !(params.cache_retention is NoCache) && params.cache_key is Some(key) {
    body["prompt_cache_key"] = Json::string(clamp_cache_key(key))
    if params.cache_retention is LongCache {
      body["prompt_cache_retention"] = Json::string("24h")
    }
  }
  Json::object(body)
}

///|
/// The text of an assistant `message` item: its `output_text` parts, joined.
fn output_text(item : Json) -> String {
  guard item is { "content": Array(parts), .. } else { return "" }
  let texts : Array[String] = []
  for part in parts {
    if part is { "type": String("output_text"), "text": String(text), .. } {
      texts.push(text)
    }
  }
  texts.join("")
}

///|
/// A reasoning item's summary, which is all of it that is meant to be read.
/// Usually empty — the model reasons, the summary is opt-in — and that is
/// fine: the block still carries the item as its signature.
fn reasoning_summary(item : Json) -> String {
  guard item is { "summary": Array(entries), .. } else { return "" }
  let texts : Array[String] = []
  for entry in entries {
    if entry is { "text": String(text), .. } {
      texts.push(text)
    }
  }
  texts.join("\n\n")
}

///|
pub impl @llm.Dialect for OpenAiResponsesDialect with fn lift_message(
  self : OpenAiResponsesDialect,
  reply : Json,
) -> @llm.ContextMessage raise @llm.DialectError {
  if @llm.api_error(reply, model=self.model) is Some(msg) {
    return msg
  }
  guard reply is { "output": Array(items), .. } else {
    raise @llm.DialectError::MalformedReply(
      "expected a response with an output list, got: \{reply.stringify()}",
    )
  }
  let blocks : Array[@llm.AssistantBlock] = []
  let mut called = false
  for item in items {
    match item {
      { "type": String("message"), .. } => {
        let text = output_text(item)
        if text != "" {
          blocks.push(AssistantText(text~, signature=message_meta(item)))
        }
      }
      { "type": String("reasoning"), .. } =>
        blocks.push(
          Thinking(
            text=reasoning_summary(item),
            signature=Some(item.stringify()),
            redacted=false,
          ),
        )
      {
        "type": String("function_call"),
        "call_id": String(id),
        "name": String(name),
        ..
      } => {
        let arguments = match item {
          { "arguments": String(raw), .. } =>
            @json.parse(raw) catch {
              _ => Json::empty_object()
            }
          _ => Json::empty_object()
        }
        called = true
        blocks.push(ToolCall(id~, name~, arguments~, signature=None))
      }
      _ => ()
    }
  }
  // There is no finish_reason here: the response has a status, and whether
  // the model wants a tool is read off the output it actually produced.
  let stop : @llm.StopReason = match reply {
    { "status": String("failed"), .. } => Errored
    { "status": String("cancelled"), .. } => Aborted
    {
      "status": String("incomplete"),
      "incomplete_details": { "reason": String("max_output_tokens"), .. },
      ..
    } => MaxTokens
    _ => if called { ToolUse } else { EndTurn }
  }
  let (model, response_id) = @llm.reply_identity(reply, fallback=self.model)
  // `input_tokens` counts the whole prefix — what was read from the cache and
  // what was written to it — so both are subtracted out rather than billed
  // twice as fresh input. Cache writes are their own line item since the
  // gpt-5.6 family, the first here to charge for them. Reasoning tokens are
  // already inside `output_tokens`.
  let usage : @llm.Usage? = match reply {
    { "usage": { "input_tokens": Number(input_tokens, ..), .. } as usage, .. } => {
      let output = match usage {
        { "output_tokens": Number(n, ..), .. } => n.to_int()
        _ => 0
      }
      let cache_read = match usage {
        { "input_tokens_details": { "cached_tokens": Number(n, ..), .. }, .. } =>
          n.to_int()
        _ => 0
      }
      let cache_write = match usage {
        {
          "input_tokens_details": { "cache_write_tokens": Number(n, ..), .. },
          ..
        } => n.to_int()
        _ => 0
      }
      Some(
        @llm.Usage::make(
          input=input_tokens.to_int() - cache_read - cache_write,
          output~,
          cache_read~,
          cache_write~,
        ),
      )
    }
    _ => None
  }
  // A `failed` response carries what went wrong under `error` on the response
  // itself, not the top-level error shape api_error matches.
  let error = match reply {
    { "error": { "message": String(message), .. }, .. } => Some(message)
    _ => None
  }
  AssistantMsg(content=blocks, stop~, model~, response_id~, usage~, error~)
}
