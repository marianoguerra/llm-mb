///|
test "lower_context produces an anthropic messages body" {
  let d = @anthropic.AnthropicDialect::make(model="test-model", max_tokens=100)
  assert_true(@llm.Dialect::id(d) == "anthropic-messages")
  let ctx : @llm.LlmContext = {
    system: Some("sys prompt"),
    messages: [
      UserMsg(content=[UserText("read a.txt")]),
      AssistantMsg(
        content=[
          @llm.AssistantBlock::ToolCall(
            id="tc1",
            name="request",
            arguments={ "verb": "READ", "uri": "file:///a.txt" },
            signature=None,
          ),
        ],
        stop=@llm.StopReason::ToolUse,
        model="test-model",
        response_id=None,
        usage=None,
        error=None,
      ),
      ToolResultMsg(
        tool_call_id="tc1",
        tool_name="request",
        content=[UserText("200 OK\n\ncontents")],
        is_error=false,
      ),
      ToolResultMsg(
        tool_call_id="tc2",
        tool_name="request",
        content=[UserText("200 OK")],
        is_error=false,
      ),
    ],
    tools: [tool_decl("describe"), tool_decl("request")],
    params: @llm.LlmParams::default(),
  }
  let body = @llm.Dialect::lower_context(d, ctx)
  guard! body
    is {
      "model": String(model),
      "system": String(system),
      "messages": Array(messages),
      "tools": Array(tools),
      ..
    }
  inspect(model, content="test-model")
  inspect(system, content="sys prompt")
  assert_eq(tools.length(), 2)
  // user, assistant, then the two consecutive tool results merged into ONE
  // user message
  assert_eq(messages.length(), 3)
  guard! messages[2]
    is { "role": String("user"), "content": Array(results), .. }
  assert_eq(results.length(), 2)
  guard! results[0]
    is { "type": String("tool_result"), "tool_use_id": String(id0), .. }
  inspect(id0, content="tc1")
  guard! messages[1]
    is { "role": String("assistant"), "content": Array([tool_use]), .. }
  guard! tool_use
    is { "type": String("tool_use"), "name": String("request"), .. }
}

///|
test "lift_message: text + tool_use + usage" {
  let d = @anthropic.AnthropicDialect::make(model="test-model")
  let reply : Json = {
    "content": [
      { "type": "text", "text": "let me read that" },
      {
        "type": "tool_use",
        "id": "tc1",
        "name": "request",
        "input": { "verb": "READ", "uri": "file:///a.txt" },
      },
    ],
    "stop_reason": "tool_use",
    "model": "test-model-20260101",
    "usage": { "input_tokens": 10, "output_tokens": 5 },
  }
  guard! @llm.Dialect::lift_message(d, reply)
    is AssistantMsg(content~, stop~, model~, usage~, error~, ..)
  assert_true(stop == @llm.StopReason::ToolUse)
  inspect(model, content="test-model-20260101")
  assert_true(error is None)
  guard! usage is Some(u)
  assert_eq(u.input, 10)
  assert_eq(u.output, 5)
  assert_eq(content.length(), 2)
  guard! content[1] is ToolCall(id~, name~, ..)
  inspect(id, content="tc1")
  inspect(name, content="request")
}

///|
test "lift_message: api errors become data, junk raises DialectError" {
  let d = @anthropic.AnthropicDialect::make()
  let api_error : Json = {
    "type": "error",
    "error": { "type": "overloaded_error", "message": "Overloaded" },
  }
  guard! @llm.Dialect::lift_message(d, api_error)
    is AssistantMsg(stop~, error~, ..)
  assert_true(stop == @llm.StopReason::Errored)
  debug_inspect(
    error,
    content=(
      #|Some("Overloaded")
    ),
  )
  try @llm.Dialect::lift_message(d, Json::string("junk")) |> ignore catch {
    @llm.DialectError::MalformedReply(_) => ()
  } noraise {
    _ => fail("expected MalformedReply")
  }
}

///|
/// An attached screenshot has to reach the model as an image, not as a
/// description of one: a text marker would leave the model answering
/// confidently about a picture it never saw.
test "an attached image lowers to an anthropic image block" {
  let d = @anthropic.AnthropicDialect::make(model="test-model", max_tokens=100)
  let ctx : @llm.LlmContext = {
    system: None,
    messages: [
      UserMsg(content=[
        UserImage(media_type="image/png", data=b"\x89PNG"),
        UserText("what colour?"),
      ]),
    ],
    tools: [],
    params: @llm.LlmParams::default(),
  }
  guard! @llm.Dialect::lower_context(d, ctx) is { "messages": Array([msg]), .. }
  json_inspect(msg, content={
    "role": "user",
    "content": [
      {
        "type": "image",
        "source": {
          "type": "base64",
          "media_type": "image/png",
          "data": "iVBORw==",
        },
      },
      { "type": "text", "text": "what colour?" },
    ],
  })
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
