// The google-generative-ai dialect: LlmContext <-> Gemini generateContent
// JSON. Quirks kept inside this impl: roles are "user"/"model" (no system
// role — the prompt goes in systemInstruction), tool calls are
// functionCall parts, tool results are functionResponse parts, and tools
// are declared under tools[].functionDeclarations.

///|
pub(all) struct GeminiDialect {
  model : String
} derive(Debug)

///|
pub fn GeminiDialect::make(model? : String) -> GeminiDialect {
  { model: model.unwrap_or("gemini-2.5-flash") }
}

///|
fn user_parts(blocks : Array[@llm.UserBlock]) -> Array[Json] {
  blocks.map(block => {
    match block {
      UserText(text) => { "text": Json::string(text) }
      UserImage(media_type~, data~) =>
        {
          "inlineData": {
            "mimeType": Json::string(media_type),
            "data": Json::string(@base64.encode(data[:])),
          },
        }
    }
  })
}

///|
pub impl @llm.Dialect for GeminiDialect with fn id(_self : GeminiDialect) -> String {
  "google-generative-ai"
}

///|
/// The one dialect for which this is not bookkeeping: the model is not in the
/// body below, it is in the URL (`/v1beta/models/<model>:generateContent`), so
/// a caller that cannot ask which model this is builds the endpoint of some
/// other one.
pub impl @llm.Dialect for GeminiDialect with fn model(self : GeminiDialect) -> String {
  self.model
}

///|
pub impl @llm.Dialect for GeminiDialect with fn lower_context(
  self : GeminiDialect,
  ctx : @llm.LlmContext,
) -> Json {
  let contents : Array[Json] = []
  for msg in ctx.messages {
    match msg {
      UserMsg(content~) =>
        contents.push({
          "role": "user",
          "parts": Json::array(user_parts(content)),
        })
      AssistantMsg(content~, model~, ..) => {
        // A thought signature is only valid for the model that minted it, so
        // a turn replayed after a model switch goes back unsigned rather than
        // with someone else's proof (pi's isSameProviderAndModel guard).
        let same_model = model == self.model
        let parts : Array[Json] = []
        for block in content {
          match block {
            AssistantText(text~, ..) =>
              parts.push({ "text": Json::string(text) })
            Thinking(..) => ()
            ToolCall(name~, arguments~, signature~, ..) => {
              let call : Map[String, Json] = {
                "functionCall": {
                  "name": Json::string(name),
                  "args": arguments,
                },
              }
              // Mandatory on Gemini 3: a functionCall replayed without the
              // thoughtSignature it came back with is rejected outright —
              // "Function call is missing a thought_signature in functionCall
              // parts", 400, every turn after the first tool call.
              if same_model && signature is Some(s) {
                call["thoughtSignature"] = Json::string(s)
              }
              parts.push(Json::object(call))
            }
          }
        }
        contents.push({ "role": "model", "parts": Json::array(parts) })
      }
      ToolResultMsg(tool_name~, content~, ..) => {
        let text = @llm.user_text(content)
        contents.push({
          "role": "user",
          "parts": [
            {
              "functionResponse": {
                "name": Json::string(tool_name),
                "response": { "result": Json::string(text) },
              },
            },
          ],
        })
      }
    }
  }
  // `parametersJsonSchema`, not `parameters`: the latter is an OpenAPI 3.0
  // subset that has no `additionalProperties`, which the `request` tool's
  // `headers` uses — so declaring our tools under it is a 400 on every call,
  // to every Gemini model. The JSON Schema field takes the schema as written.
  let function_declarations : Array[Json] = ctx.tools.map(tool => {
    (
      {
        "name": Json::string(tool.name),
        "description": Json::string(tool.description),
        "parametersJsonSchema": tool.input_schema,
      } : Json)
  })
  let body : Map[String, Json] = {
    "contents": Json::array(contents),
    "tools": [{ "functionDeclarations": Json::array(function_declarations) }],
  }
  if ctx.system is Some(system) {
    body["systemInstruction"] = { "parts": [{ "text": Json::string(system) }] }
  }
  Json::object(body)
}

///|
fn stop_reason_of(raw : String) -> @llm.StopReason {
  match raw {
    "MAX_TOKENS" => MaxTokens
    "SAFETY" | "RECITATION" | "BLOCKLIST" | "PROHIBITED_CONTENT" => Errored
    _ => EndTurn // STOP, and anything unknown
  }
}

///|
pub impl @llm.Dialect for GeminiDialect with fn lift_message(
  self : GeminiDialect,
  reply : Json,
) -> @llm.ContextMessage raise @llm.DialectError {
  if @llm.api_error(reply, model=self.model) is Some(msg) {
    return msg
  }
  guard reply is { "candidates": Array([candidate, ..]), .. } &&
    candidate is { "content": { "parts": Array(raw_parts), .. }, .. } else {
    raise @llm.DialectError::MalformedReply(
      "expected candidates[0].content.parts, got: \{reply.stringify()}",
    )
  }
  let blocks : Array[@llm.AssistantBlock] = []
  let mut tool_seq = 0
  for raw in raw_parts {
    // thoughtSignature rides on the PART, not on the call inside it, and can
    // appear over any kind of part — text as readily as a function call. It
    // has to come back on the turn that replays the part, so it is lifted
    // onto whichever block this part becomes.
    let signature = match raw {
      { "thoughtSignature": String(s), .. } => Some(s)
      _ => None
    }
    match raw {
      { "text": String(text), .. } =>
        blocks.push(AssistantText(text~, signature~))
      { "functionCall": { "name": String(name), .. } as call, .. } => {
        let arguments = match call {
          { "args": args, .. } => args
          _ => Json::empty_object()
        }
        // Gemini 2.x function calls carry no id; synthesize a stable one.
        // (Gemini 3 does send one, but replaying it is only expected for the
        // non-Gemini models served behind this API, so it is not kept.)
        let id = "gemini-call-\{tool_seq}"
        tool_seq = tool_seq + 1
        blocks.push(ToolCall(id~, name~, arguments~, signature~))
      }
      _ => ()
    }
  }
  let stop = match candidate {
    { "finishReason": String(raw_finish), .. } => stop_reason_of(raw_finish)
    _ => EndTurn
  }
  // `promptTokenCount` counts the whole prefix, the cached part included, so
  // `cachedContentTokenCount` is subtracted out rather than billed twice as
  // fresh input. Google caches implicitly from 2.5 onward and says so only
  // here, so a reply that never asked for caching still reports it — and a
  // reader that ignored the field would price a hit as a miss.
  let usage : @llm.Usage? = match reply {
    {
      "usageMetadata": {
        "promptTokenCount": Number(input_tokens, ..),
        "candidatesTokenCount": Number(output_tokens, ..),
        ..
      } as counts,
      ..
    } => {
      let cache_read = match counts {
        { "cachedContentTokenCount": Number(n, ..), .. } => n.to_int()
        _ => 0
      }
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
  let response_id = match reply {
    { "responseId": String(id), .. } => Some(id)
    _ => None
  }
  AssistantMsg(
    content=blocks,
    stop~,
    model=self.model,
    response_id~,
    usage~,
    error=None,
  )
}

///|
/// This dialect as a registry entry. Gemini's endpoint carries the model, so
/// `model()` is load-bearing here in a way it is not for the other three.
pub fn api_spec() -> @llm.ApiSpec {
  {
    id: "google-generative-ai",
    make: info => GeminiDialect::make(model=info.id),
    caps: id => @llm.ModelInfo::permissive(id),
  }
}
