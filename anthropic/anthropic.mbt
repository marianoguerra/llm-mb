///|
pub fn AnthropicDialect::make(
  model? : String,
  max_tokens? : Int,
) -> AnthropicDialect {
  {
    model: model.unwrap_or("claude-sonnet-5"),
    max_tokens: max_tokens.unwrap_or(8192),
  }
}

///|
fn user_blocks_json(blocks : Array[@llm.UserBlock]) -> Array[Json] {
  blocks.map(block => {
    match block {
      UserText(text) => { "type": "text", "text": Json::string(text) }
      UserImage(media_type~, data~) =>
        {
          "type": "image",
          "source": {
            "type": "base64",
            "media_type": Json::string(media_type),
            "data": Json::string(@base64.encode(data[:])),
          },
        }
    }
  })
}

///|
fn assistant_blocks_json(blocks : Array[@llm.AssistantBlock]) -> Array[Json] {
  let out : Array[Json] = []
  for block in blocks {
    match block {
      AssistantText(text~, ..) =>
        out.push({ "type": "text", "text": Json::string(text) })
      Thinking(text~, signature~, ..) =>
        // replaying thinking requires its signature; unsigned thinking is
        // dropped from the wire (it stays in the log)
        if signature is Some(sig) {
          out.push({
            "type": "thinking",
            "thinking": Json::string(text),
            "signature": Json::string(sig),
          })
        }
      ToolCall(id~, name~, arguments~, ..) =>
        out.push({
          "type": "tool_use",
          "id": Json::string(id),
          "name": Json::string(name),
          "input": arguments,
        })
    }
  }
  out
}

///|
/// Where a breakpoint may sit.
///
/// Anthropic takes one on a content block, and a request is made of four
/// kinds. A thought is not among them: it is replayed for its signature, and
/// what a cache is asked to keep is the prefix a person built, not the
/// model's own working.
fn cacheable(block : Json) -> Bool {
  match block {
    { "type": String("text"), .. }
    | { "type": String("image"), .. }
    | { "type": String("tool_use"), .. }
    | { "type": String("tool_result"), .. } => true
    _ => false
  }
}

///|
/// The marker that says "keep everything up to here", or nothing when the
/// caller asked for no caching.
///
/// Anthropic's caching is opt-in and per breakpoint — nothing is kept unless
/// the request says where the stable part ends, which is the difference
/// between this API and OpenAI's. `ttl` is only spelled for the long tier,
/// because the five-minute one is what the field defaults to.
fn cache_marker(retention : @llm.CacheRetention) -> Json? {
  match retention {
    NoCache => None
    ShortCache => Some({ "type": "ephemeral" })
    LongCache => Some({ "type": "ephemeral", "ttl": "1h" })
  }
}

///|
/// One block with a breakpoint on it — a copy, so nothing the caller handed
/// over is marked behind its back.
fn marked(block : Json, marker : Json) -> Json {
  guard block is Object(fields) else { return block }
  let out : Map[String, Json] = Map([])
  for key, value in fields {
    out.set(key, value)
  }
  out.set("cache_control", marker)
  Json::object(out)
}

///|
/// Put a breakpoint at the end of one message, and say whether it landed.
///
/// The LAST block that can take one, walking back past the thoughts: a
/// breakpoint keeps everything in front of it, so the further into the
/// message it sits, the more of the conversation the next turn reads back.
fn mark_message(message : Json, marker : Json) -> Bool {
  guard message is Object(fields) else { return false }
  guard fields.get("content") is Some(Array(blocks)) else { return false }
  let mut i = blocks.length() - 1
  while i >= 0 {
    if cacheable(blocks[i]) {
      blocks[i] = marked(blocks[i], marker)
      return true
    }
    i = i - 1
  }
  false
}

///|
pub impl @llm.Dialect for AnthropicDialect with fn id(_self : AnthropicDialect) -> String {
  "anthropic-messages"
}

///|
pub impl @llm.Dialect for AnthropicDialect with fn model(
  self : AnthropicDialect,
) -> String {
  self.model
}

///|
pub impl @llm.Dialect for AnthropicDialect with fn lower_context(
  self : AnthropicDialect,
  ctx : @llm.LlmContext,
) -> Json {
  let messages : Array[Json] = []
  // Anthropic wants all tool_result blocks for one assistant turn inside a
  // single following user message: merge consecutive ToolResultMsgs.
  let pending_results : Array[Json] = []
  fn flush_results() {
    if pending_results.length() > 0 {
      messages.push({
        "role": "user",
        "content": Json::array(pending_results.copy()),
      })
      pending_results.clear()
    }
  }
  for msg in ctx.messages {
    match msg {
      ToolResultMsg(tool_call_id~, content~, is_error~, ..) =>
        pending_results.push({
          "type": "tool_result",
          "tool_use_id": Json::string(tool_call_id),
          "content": Json::array(user_blocks_json(content)),
          "is_error": Json::boolean(is_error),
        })
      UserMsg(content~) => {
        flush_results()
        messages.push({
          "role": "user",
          "content": Json::array(user_blocks_json(content)),
        })
      }
      AssistantMsg(content~, ..) => {
        flush_results()
        messages.push({
          "role": "assistant",
          "content": Json::array(assistant_blocks_json(content)),
        })
      }
    }
  }
  flush_results()
  let marker = cache_marker(ctx.params.cache_retention)
  let tools = ctx.tools.map(tool => {
    (
      {
        "name": Json::string(tool.name),
        "description": Json::string(tool.description),
        "input_schema": tool.input_schema,
      } : Json)
  })
  // The breakpoints, from the front of the prompt to the back. Four is the
  // limit and four is what this places, because the four are the boundaries
  // this API actually has: the tool declarations, the system prompt, and the
  // last two messages.
  //
  // The two at the back are what makes a growing conversation cache at all.
  // A breakpoint writes an entry for the prefix in front of it, so the one on
  // the final message is what the NEXT turn reads back, and the one on the
  // message before it is the entry the current turn is reading — kept marked
  // so it survives while the newer write is still landing.
  //
  // Nothing marks a thought or an unfinished turn, and nothing marks anything
  // at all when the caller asked for no caching: an unmarked request is the
  // one this dialect used to send, and it was billed at full price for a
  // prefix the provider already had.
  if marker is Some(marker) {
    if tools.length() > 0 {
      tools[tools.length() - 1] = marked(tools[tools.length() - 1], marker)
    }
    let mut left = 2
    let mut i = messages.length() - 1
    while i >= 0 && left > 0 {
      if mark_message(messages[i], marker) {
        left = left - 1
      }
      i = i - 1
    }
  }
  let body : Map[String, Json] = {
    "model": Json::string(self.model),
    "max_tokens": Json::number(self.max_tokens.to_double()),
    "messages": Json::array(messages),
    "tools": Json::array(tools),
  }
  if ctx.system is Some(system) {
    // A string until there is a breakpoint to hang on it: `system` takes
    // either spelling, and the array form exists here only because a marker
    // has to sit on a block.
    body["system"] = match marker {
      Some(marker) =>
        Json::array([
          {
            "type": "text",
            "text": Json::string(system),
            "cache_control": marker,
          },
        ])
      None => Json::string(system)
    }
  }
  Json::object(body)
}

///|
fn stop_reason_of(raw : String) -> @llm.StopReason {
  match raw {
    "max_tokens" => MaxTokens
    "tool_use" => ToolUse
    "refusal" => Errored
    _ => EndTurn // end_turn, stop_sequence
  }
}

///|
pub impl @llm.Dialect for AnthropicDialect with fn lift_message(
  self : AnthropicDialect,
  reply : Json,
) -> @llm.ContextMessage raise @llm.DialectError {
  if @llm.api_error(reply, model=self.model) is Some(msg) {
    return msg
  }
  guard reply is { "content": Array(raw_blocks), .. } else {
    raise @llm.DialectError::MalformedReply(
      "expected a messages reply with a content array, got: \{reply.stringify()}",
    )
  }
  let blocks : Array[@llm.AssistantBlock] = []
  for raw in raw_blocks {
    match raw {
      { "type": "text", "text": String(text), .. } =>
        blocks.push(AssistantText(text~, signature=None))
      { "type": "thinking", "thinking": String(text), .. } => {
        let signature = match raw {
          { "signature": String(sig), .. } => Some(sig)
          _ => None
        }
        blocks.push(Thinking(text~, signature~, redacted=false))
      }
      { "type": "tool_use", "id": String(id), "name": String(name), .. } => {
        let arguments = match raw {
          { "input": input, .. } => input
          _ => Json::empty_object()
        }
        blocks.push(ToolCall(id~, name~, arguments~, signature=None))
      }
      _ => () // unknown block types are skipped, not fatal
    }
  }
  let stop = match reply {
    { "stop_reason": String(raw_stop), .. } => stop_reason_of(raw_stop)
    _ => EndTurn
  }
  let (model, response_id) = @llm.reply_identity(reply, fallback=self.model)
  let usage : @llm.Usage? = match reply {
    {
      "usage": {
        "input_tokens": Number(input_tokens, ..),
        "output_tokens": Number(output_tokens, ..),
        ..
      } as u,
      ..
    } => {
      let cache_read = match u {
        { "cache_read_input_tokens": Number(n, ..), .. } => n.to_int()
        _ => 0
      }
      let cache_write = match u {
        { "cache_creation_input_tokens": Number(n, ..), .. } => n.to_int()
        _ => 0
      }
      Some(
        @llm.Usage::make(
          input=input_tokens.to_int(),
          output=output_tokens.to_int(),
          cache_read~,
          cache_write~,
        ),
      )
    }
    _ => None
  }
  AssistantMsg(content=blocks, stop~, model~, response_id~, usage~, error=None)
}

///|
/// This dialect as a registry entry: how to build one for a model, and what
/// to assume about a model nobody wrote a row for.
///
/// Anthropic has no probed capability table — its effort dial is not a dial
/// at all, it is a thinking-token budget — so an unlisted model gets the
/// permissive assumptions, which is what every model here got anyway.
pub fn api_spec() -> @llm.ApiSpec {
  {
    id: "anthropic-messages",
    make: info => AnthropicDialect::make(model=info.id),
    caps: id => @llm.ModelInfo::permissive(id),
  }
}
