// The openai-completions dialect: LlmContext <-> OpenAI Chat Completions
// JSON. Notable quirks kept inside this impl, never in the IR: tool
// arguments travel as a JSON *string*, tool results are role:"tool"
// messages, and the system prompt is a leading message.

///|
/// The model's row travels with the dialect rather than being looked up in
/// `lower_context`, because this API is spoken by vendors whose models are
/// not in OpenAI's table: `openai_model("gpt-oss-120b")` answers `permissive`
/// and would claim every thinking level, including the `none` that model does
/// not have. The registry already resolved the right row — `ApiSpec::make`
/// is handed it — so the dialect takes it instead of guessing.
pub(all) struct OpenAiDialect {
  model : String
  info : @llm.ModelInfo
} derive(Debug)

///|
/// `info` defaults to OpenAI's own table, which is what a caller naming only
/// a model means, and what every call site meant before the field existed.
pub fn OpenAiDialect::make(
  model? : String,
  info? : @llm.ModelInfo,
) -> OpenAiDialect {
  let model = model.unwrap_or("gpt-5.4-mini")
  { model, info: info.unwrap_or(openai_model(model)), }
}

///|
pub impl @llm.Dialect for OpenAiDialect with fn id(_self : OpenAiDialect) -> String {
  "openai-completions"
}

///|
pub impl @llm.Dialect for OpenAiDialect with fn model(self : OpenAiDialect) -> String {
  self.model
}

///|
/// A user turn's content. This API takes either a plain string or an array
/// of typed parts; a turn with no image stays a string so the common request
/// is byte-for-byte what it always was, and only an attached image promotes
/// it to the array form.
fn user_content(blocks : Array[@llm.UserBlock]) -> Json {
  if !blocks.iter().any(block => block is UserImage(..)) {
    return Json::string(@llm.user_text(blocks))
  }
  Json::array(
    blocks.map(block => {
      match block {
        UserText(text) => { "type": "text", "text": Json::string(text) }
        UserImage(media_type~, data~) =>
          {
            "type": "image_url",
            "image_url": {
              "url": Json::string(
                "data:\{media_type};base64,\{@base64.encode(data[:])}",
              ),
            },
          }
      }
    }),
  )
}

///|
pub impl @llm.Dialect for OpenAiDialect with fn lower_context(
  self : OpenAiDialect,
  ctx : @llm.LlmContext,
) -> Json {
  let messages : Array[Json] = []
  if ctx.system is Some(system) {
    messages.push({ "role": "system", "content": Json::string(system) })
  }
  for msg in ctx.messages {
    match msg {
      UserMsg(content~) =>
        messages.push({ "role": "user", "content": user_content(content) })
      AssistantMsg(content~, ..) => {
        let texts : Array[String] = []
        let tool_calls : Array[Json] = []
        for block in content {
          match block {
            AssistantText(text~, ..) => texts.push(text)
            Thinking(..) => () // thinking is not replayable on this API
            ToolCall(id~, name~, arguments~, ..) =>
              tool_calls.push({
                "type": "function",
                "id": Json::string(id),
                "function": {
                  "name": Json::string(name),
                  "arguments": Json::string(arguments.stringify()),
                },
              })
          }
        }
        let entry : Map[String, Json] = { "role": "assistant" }
        entry["content"] = if texts.length() > 0 {
          Json::string(texts.join("\n\n"))
        } else {
          Json::null()
        }
        if tool_calls.length() > 0 {
          entry["tool_calls"] = Json::array(tool_calls)
        }
        messages.push(Json::object(entry))
      }
      ToolResultMsg(tool_call_id~, content~, ..) =>
        messages.push({
          "role": "tool",
          "tool_call_id": Json::string(tool_call_id),
          "content": Json::string(@llm.user_text(content)),
        })
    }
  }
  let body : Map[String, Json] = {
    "model": Json::string(self.model),
    "messages": Json::array(messages),
    "tools": Json::array(
      ctx.tools.map(tool => {
        (
          {
            "type": "function",
            "function": {
              "name": Json::string(tool.name),
              "description": Json::string(tool.description),
              "parameters": tool.input_schema,
            },
          } : Json)
      }),
    ),
  }
  let params = ctx.params
  // How hard to think. Asked for nothing means say nothing — the model's own
  // default applies — so a caller who sets no params gets the body this
  // dialect has always sent, unchanged. A level this model does not have is
  // clamped to the nearest it does: `gpt-oss-120b` has no `none`, and asking
  // one for it is a 400 rather than a downgrade.
  if self.info.reasoning && params.effort is Some(level) {
    if self.info.clamp_effort(level) is Some(name) {
      body["reasoning_effort"] = Json::string(name)
    }
  }
  // `max_completion_tokens`, not `max_tokens`: the second is deprecated on
  // OpenAI's own API and the vendors that borrow this protocol take the
  // first. Sending both is an error everywhere, so only one goes.
  if params.max_output_tokens is Some(want) {
    let capped = match self.info.max_output_tokens {
      Some(cap) => if want < cap { want } else { cap }
      None => want
    }
    // Same floor as the responses path: a cap under 16 is a mistake rather
    // than an intent, so it is raised instead of refused.
    body["max_completion_tokens"] = Json::number(
      (if capped < 16 { 16 } else { capped }).to_double(),
    )
  }
  // What is NOT here, and why: `pro_mode`, `reasoning_context` and
  // `reasoning_summary` are Responses-API shapes with no chat-completions
  // spelling, and `cache_key`/`cache_retention` lower to `prompt_cache_*`,
  // which is OpenAI's own — firing it at every compatible vendor is how a
  // shared mapping starts 400ing for the ones that never asked for it.
  Json::object(body)
}

///|
fn stop_reason_of(raw : String) -> @llm.StopReason {
  match raw {
    "length" => MaxTokens
    "tool_calls" | "function_call" => ToolUse
    "content_filter" => Errored
    _ => EndTurn // stop
  }
}

///|
pub impl @llm.Dialect for OpenAiDialect with fn lift_message(
  self : OpenAiDialect,
  reply : Json,
) -> @llm.ContextMessage raise @llm.DialectError {
  if @llm.api_error(reply, model=self.model) is Some(msg) {
    return msg
  }
  // Two shapes answer on this protocol. OpenAI's own is `choices[]`, each
  // wrapping a `message` and carrying the `finish_reason` beside it.
  // OpenRouter answers some calls with a bare `messages[]` instead — the turn
  // without the wrapper, and so without a finish reason. Both are read,
  // because a reply this could not lift is a turn lost, and the one thing the
  // wrapper carries that the message does not is recoverable from the blocks.
  let (message, choice) = match reply {
    { "choices": Array([choice, ..]), .. } if choice
      is { "message": message, .. } => (message, choice)
    { "messages": Array([.., last]), .. } => (last, last)
    _ =>
      raise @llm.DialectError::MalformedReply(
        "expected a chat completion with choices or messages, got: \{reply.stringify()}",
      )
  }
  let blocks : Array[@llm.AssistantBlock] = []
  if message is { "content": String(text), .. } && text != "" {
    blocks.push(AssistantText(text~, signature=None))
  }
  if message is { "tool_calls": Array(raw_calls), .. } {
    for raw in raw_calls {
      guard raw
        is {
          "id": String(id),
          "function": {
            "name": String(name),
            "arguments": String(raw_args),
            ..
          },
          ..
        } else {
        continue
      }
      let arguments = @json.parse(raw_args) catch { _ => Json::empty_object() }
      blocks.push(ToolCall(id~, name~, arguments~, signature=None))
    }
  }
  // A `finish_reason` when the reply has one, and the blocks themselves when
  // it does not: a turn that asked for a tool is a turn that stopped for one,
  // whatever the envelope did or did not say.
  let stop = match choice {
    { "finish_reason": String(raw_finish), .. } => stop_reason_of(raw_finish)
    _ =>
      if blocks.iter().any(block => block is ToolCall(..)) {
        ToolUse
      } else {
        EndTurn
      }
  }
  let (model, response_id) = @llm.reply_identity(reply, fallback=self.model)
  // `prompt_tokens` counts the whole prefix, the part that came back from the
  // cache included, so what was cached is subtracted out rather than billed
  // twice as fresh input. The detail object is where every vendor on this
  // protocol reports it — OpenAI names it `prompt_tokens_details`, and
  // OpenRouter passes the same shape through from whichever provider served
  // the call. A reply without one cached nothing, which is the zero.
  let usage : @llm.Usage? = match reply {
    {
      "usage": {
        "prompt_tokens": Number(input_tokens, ..),
        "completion_tokens": Number(output_tokens, ..),
        ..
      } as usage,
      ..
    } => {
      let cache_read = match usage {
        { "prompt_tokens_details": { "cached_tokens": Number(n, ..), .. }, .. } =>
          n.to_int()
        _ => 0
      }
      // No cache-write line: this protocol has nowhere to ask for a write and
      // no vendor on it reports one. `cache_write` stays zero, which is the
      // true count and not a gap.
      Some(
        @llm.Usage::make(
          input=input_tokens.to_int() - cache_read,
          output=output_tokens.to_int(),
          cache_read~,
        ),
      )
    }
    _ => None
  }
  AssistantMsg(content=blocks, stop~, model~, response_id~, usage~, error=None)
}
