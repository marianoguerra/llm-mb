// The openai-completions dialect: LlmContext <-> OpenAI Chat Completions
// JSON. Notable quirks kept inside this impl, never in the IR: tool
// arguments travel as a JSON *string*, tool results are role:"tool"
// messages, and the system prompt is a leading message.

///|
pub(all) struct OpenAiDialect {
  model : String
} derive(Debug)

///|
pub fn OpenAiDialect::make(model? : String) -> OpenAiDialect {
  { model: model.unwrap_or("gpt-5.4-mini") }
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
  {
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
  guard reply is { "choices": Array([choice, ..]), .. } &&
    choice is { "message": message, .. } else {
    raise @llm.DialectError::MalformedReply(
      "expected a chat completion with choices, got: \{reply.stringify()}",
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
  let stop = match choice {
    { "finish_reason": String(raw_finish), .. } => stop_reason_of(raw_finish)
    _ => EndTurn
  }
  let (model, response_id) = @llm.reply_identity(reply, fallback=self.model)
  let usage : @llm.Usage? = match reply {
    {
      "usage": {
        "prompt_tokens": Number(input_tokens, ..),
        "completion_tokens": Number(output_tokens, ..),
        ..
      },
      ..
    } =>
      Some(
        @llm.Usage::make(
          input=input_tokens.to_int(),
          output=output_tokens.to_int(),
        ),
      )
    _ => None
  }
  AssistantMsg(content=blocks, stop~, model~, response_id~, usage~, error=None)
}
