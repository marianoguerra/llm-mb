///|
test "openrouter reuses the openai chat-completions mapping, own id" {
  let d = @openrouter.OpenRouterDialect::make(model="anthropic/claude-sonnet-5")
  assert_true(@llm.Dialect::id(d) == "openrouter")
  let ctx : @llm.LlmContext = {
    system: Some("sys"),
    messages: [UserMsg(content=[UserText("hi")])],
    tools: [tool_decl("request")],
    params: @llm.LlmParams::default(),
  }
  // same wire shape as openai: role-tagged messages + function tools
  let body = @llm.Dialect::lower_context(d, ctx)
  guard! body
    is { "model": String(model), "messages": Array(msgs), "tools": _, .. }
  inspect(model, content="anthropic/claude-sonnet-5")
  guard! msgs[0] is { "role": String("system"), .. }
  // lift a chat-completion reply with a tool call
  let reply : Json = {
    "choices": [
      {
        "message": {
          "content": "sure",
          "tool_calls": [
            {
              "id": "c1",
              "function": {
                "name": "request",
                "arguments": "{\"verb\":\"READ\",\"uri\":\"file:///a\"}",
              },
            },
          ],
        },
        "finish_reason": "tool_calls",
      },
    ],
  }
  guard! @llm.Dialect::lift_message(d, reply)
    is AssistantMsg(content~, stop~, ..)
  assert_true(stop == @llm.StopReason::ToolUse)
  guard! content[content.length() - 1] is ToolCall(name~, arguments~, ..)
  inspect(name, content="request")
  guard! arguments is { "verb": String(verb), .. }
  inspect(verb, content="READ")
}

///|
/// A tool to lower, and nothing more. What a caller's tools actually say is
/// the embedding application's business; a dialect test only needs one decl
/// to watch travel into the provider's own spelling of a tool list.
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
