///|
test "gemini lower_context: system → systemInstruction, roles user/model" {
  let d = @gemini.GeminiDialect::make(model="gemini-2.5-flash")
  assert_true(@llm.Dialect::id(d) == "google-generative-ai")
  let ctx : @llm.LlmContext = {
    system: Some("sys"),
    messages: [
      UserMsg(content=[UserText("hi")]),
      AssistantMsg(
        content=[
          @llm.AssistantBlock::ToolCall(
            id="c0",
            name="request",
            arguments={ "verb": "READ", "uri": "file:///a" },
            signature=None,
          ),
        ],
        stop=@llm.StopReason::ToolUse,
        model="m",
        response_id=None,
        usage=None,
        error=None,
      ),
    ],
    tools: [tool_decl("request")],
    params: @llm.LlmParams::default(),
  }
  let body = @llm.Dialect::lower_context(d, ctx)
  guard! body
    is {
      "contents": Array(contents),
      "systemInstruction": _,
      "tools": Array([tools0]),
      ..
    }
  assert_eq(contents.length(), 2)
  guard! contents[0] is { "role": String("user"), .. }
  guard! contents[1] is { "role": String("model"), "parts": Array([fc]), .. }
  guard! fc is { "functionCall": { "name": String("request"), .. }, .. }
  // The schema goes under `parametersJsonSchema`. `parameters` is an OpenAPI
  // 3.0 subset with no `additionalProperties`, which the request tool's
  // `headers` uses — declaring it there is a 400 on every call.
  guard! tools0 is { "functionDeclarations": Array(decls), .. }
  assert_eq(decls.length(), 1)
  guard! decls[0] is { "parametersJsonSchema": schema, .. }
  assert_true(schema is { "type": String("object"), .. })
}

///|
/// Gemini 3 rejects a functionCall replayed without the thoughtSignature it
/// came back with, so the signature has to survive lift → log → lower. It is
/// only valid for the model that minted it: a turn carried over a model
/// switch goes back unsigned rather than with someone else's proof.
test "gemini lower_context: a tool call replays its thought signature" {
  fn ctx_with(model : String) -> @llm.LlmContext {
    {
      system: None,
      messages: [
        AssistantMsg(
          content=[
            @llm.AssistantBlock::ToolCall(
              id="c0",
              name="request",
              arguments={ "verb": "READ", "uri": "file:///a" },
              signature=Some("SIG"),
            ),
          ],
          stop=@llm.StopReason::ToolUse,
          model~,
          response_id=None,
          usage=None,
          error=None,
        ),
      ],
      tools: [],
      params: @llm.LlmParams::default(),
    }
  }

  let d = @gemini.GeminiDialect::make(model="gemini-3.6-flash")
  guard! @llm.Dialect::lower_context(d, ctx_with("gemini-3.6-flash"))
    is { "contents": Array([{ "parts": Array([signed]), .. }]), .. }
  assert_true(signed is { "thoughtSignature": String("SIG"), .. })
  // same signature, different model: dropped rather than replayed
  guard! @llm.Dialect::lower_context(d, ctx_with("claude-sonnet-5"))
    is { "contents": Array([{ "parts": Array([unsigned]), .. }]), .. }
  assert_true(!(unsigned is { "thoughtSignature": _, .. }))
}

///|
test "gemini lift_message: text + functionCall + finishReason" {
  let d = @gemini.GeminiDialect::make()
  let reply : Json = {
    "candidates": [
      {
        "content": {
          "parts": [
            { "text": "ok" },
            {
              "functionCall": { "name": "request", "args": { "verb": "LIST" } },
              // Rides on the part, not on the call inside it.
              "thoughtSignature": "SIG",
            },
          ],
        },
        "finishReason": "STOP",
      },
    ],
    "usageMetadata": { "promptTokenCount": 3, "candidatesTokenCount": 4 },
  }
  guard! @llm.Dialect::lift_message(d, reply)
    is AssistantMsg(content~, usage~, ..)
  assert_eq(content.length(), 2)
  guard! content[1] is ToolCall(name~, signature~, ..)
  inspect(name, content="request")
  assert_true(signature is Some("SIG"))
  // An unsigned part stays unsigned — not signed with the empty string.
  guard! content[0] is AssistantText(signature=text_signature, ..)
  assert_true(text_signature is None)
  guard! usage is Some(u)
  assert_eq(u.input, 3)
}

///|
test "gemini lift: api errors are data" {
  let d = @gemini.GeminiDialect::make()
  guard! @llm.Dialect::lift_message(d, {
      "error": { "message": "quota exceeded" },
    })
    is AssistantMsg(stop~, error~, ..)
  assert_true(stop == @llm.StopReason::Errored)
  assert_true(error is Some("quota exceeded"))
}

///|
/// A tool to lower, and nothing more. What the hypermedia client's two tools
/// actually say is the embedding application's business; a dialect test only
/// needs one decl to watch travel into the provider's own spelling of a tool
/// list.
fn tool_decl(name : String) -> @llm.ToolDecl {
  {
    name,
    description: "Perform a request against a route.",
    input_schema: {
      "type": "object",
      "properties": {
        "verb": { "type": "string" },
        "uri": { "type": "string" },
      },
      "required": ["verb", "uri"],
    },
  }
}
