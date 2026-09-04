///|
test "openai lower_context: system message, tool args as JSON string" {
  let d = @openai.OpenAiDialect::make(model="gpt-5.4-mini")
  assert_true(@llm.Dialect::id(d) == "openai-completions")
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
      ToolResultMsg(
        tool_call_id="c0",
        tool_name="request",
        content=[UserText("contents")],
        is_error=false,
      ),
    ],
    tools: [tool_decl("request")],
    params: @llm.LlmParams::default(),
  }
  let body = @llm.Dialect::lower_context(d, ctx)
  guard! body
    is {
      "model": String("gpt-5.4-mini"),
      "messages": Array(messages),
      "tools": Array(tools),
      ..
    }
  // system + user + assistant + tool result
  assert_eq(messages.length(), 4)
  guard! messages[0] is { "role": String("system"), .. }
  guard! messages[2]
    is { "role": String("assistant"), "tool_calls": Array([call0]), .. }
  // the quirk: arguments travel as a JSON *string*, not an object
  guard! call0 is { "function": { "arguments": String(raw_args), .. }, .. }
  guard! @json.parse(raw_args) is { "verb": String("READ"), .. }
  guard! messages[3]
    is { "role": String("tool"), "tool_call_id": String("c0"), .. }
  assert_eq(tools.length(), 1)
}

///|
test "openai lift_message: text + tool_calls + finish_reason + usage" {
  let d = @openai.OpenAiDialect::make()
  let reply : Json = {
    "model": "gpt-5.4-mini",
    "choices": [
      {
        "message": {
          "content": "ok",
          "tool_calls": [
            {
              "id": "call-1",
              "function": {
                "name": "request",
                "arguments": "{\"verb\": \"LIST\"}",
              },
            },
          ],
        },
        "finish_reason": "tool_calls",
      },
    ],
    "usage": { "prompt_tokens": 3, "completion_tokens": 4 },
  }
  guard! @llm.Dialect::lift_message(d, reply)
    is AssistantMsg(content~, stop~, usage~, ..)
  assert_eq(content.length(), 2)
  guard! content[1] is ToolCall(id~, name~, arguments~, ..)
  inspect(id, content="call-1")
  inspect(name, content="request")
  guard! arguments is { "verb": String("LIST"), .. }
  assert_true(stop == @llm.StopReason::ToolUse)
  guard! usage is Some(u)
  assert_eq(u.input, 3)
  assert_eq(u.output, 4)
}

///|
test "openai lift: finish_reason mapping" {
  let d = @openai.OpenAiDialect::make()
  fn lift_stop(raw : String) -> @llm.StopReason raise {
    let reply : Json = {
      "choices": [{ "message": { "content": "x" }, "finish_reason": raw }],
    }
    guard! @llm.Dialect::lift_message(d, reply) is AssistantMsg(stop~, ..)
    stop
  }

  assert_true(lift_stop("length") == @llm.StopReason::MaxTokens)
  assert_true(lift_stop("tool_calls") == @llm.StopReason::ToolUse)
  assert_true(lift_stop("content_filter") == @llm.StopReason::Errored)
  assert_true(lift_stop("stop") == @llm.StopReason::EndTurn)
}

///|
test "openai lift: api errors are data" {
  let d = @openai.OpenAiDialect::make()
  guard! @llm.Dialect::lift_message(d, {
      "error": { "message": "rate limited" },
    })
    is AssistantMsg(stop~, error~, ..)
  assert_true(stop == @llm.StopReason::Errored)
  assert_true(error is Some("rate limited"))
}

///|
test "openai lift: malformed reply raises" {
  let d = @openai.OpenAiDialect::make()
  try @llm.Dialect::lift_message(d, { "nope": true }) catch {
    @llm.DialectError::MalformedReply(_) => ()
  } noraise {
    _ => fail("expected a malformed reply to raise")
  }
}

///|
/// This API takes a string or an array of parts. A text-only turn stays a
/// string — the shape every existing request already had — and only an
/// attached image promotes it.
test "an attached image promotes user content to the array form" {
  let d = @openai.OpenAiDialect::make(model="test-model")
  let text_only : @llm.LlmContext = {
    system: None,
    messages: [UserMsg(content=[UserText("hello")])],
    tools: [],
    params: @llm.LlmParams::default(),
  }
  guard! @llm.Dialect::lower_context(d, text_only)
    is { "messages": Array([plain]), .. }
  json_inspect(plain, content={ "role": "user", "content": "hello" })
  let with_image : @llm.LlmContext = {
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
  guard! @llm.Dialect::lower_context(d, with_image)
    is { "messages": Array([promoted]), .. }
  json_inspect(promoted, content={
    "role": "user",
    "content": [
      {
        "type": "image_url",
        "image_url": { "url": "data:image/png;base64,iVBORw==" },
      },
      { "type": "text", "text": "what colour?" },
    ],
  })
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

///|
/// What a cached prefix costs is a tenth of what a fresh one does, so the two
/// halves of `prompt_tokens` are not interchangeable and a lift that reported
/// the sum as fresh input priced every hit as a miss. OpenRouter speaks this
/// protocol and passes the same detail object through, so this is what it
/// reports too.
test "lift_message: the cached half of the prompt is counted apart" {
  let d = @openai.OpenAiDialect::make(model="test-model")
  let reply : Json = {
    "choices": [
      {
        "message": { "role": "assistant", "content": "hi" },
        "finish_reason": "stop",
      },
    ],
    "model": "test-model",
    "usage": {
      "prompt_tokens": 10000,
      "completion_tokens": 50,
      "total_tokens": 10050,
      "prompt_tokens_details": { "cached_tokens": 9000 },
    },
  }
  guard! @llm.Dialect::lift_message(d, reply) is AssistantMsg(usage~, ..)
  guard! usage is Some(u)
  assert_eq(u.cache_read, 9000)
  assert_eq(u.input, 1000)
  assert_eq(u.output, 50)
}

///|
/// A reply from a vendor that reports no details cached nothing, and says so
/// by leaving the object out. The whole prompt is fresh input, which is what
/// this protocol looked like before caching existed.
test "lift_message: no details means nothing was cached" {
  let d = @openai.OpenAiDialect::make(model="test-model")
  let reply : Json = {
    "choices": [
      {
        "message": { "role": "assistant", "content": "hi" },
        "finish_reason": "stop",
      },
    ],
    "model": "test-model",
    "usage": { "prompt_tokens": 300, "completion_tokens": 12 },
  }
  guard! @llm.Dialect::lift_message(d, reply) is AssistantMsg(usage~, ..)
  guard! usage is Some(u)
  assert_eq(u.cache_read, 0)
  assert_eq(u.input, 300)
}

///|
/// The other shape that answers on this protocol.
///
/// OpenRouter returns the turn as a bare `messages[]` — no `choices` wrapper,
/// and so no `finish_reason` to read a stop reason off. A lift that insisted
/// on the wrapper refused the whole reply, which is a turn lost rather than a
/// count mis-read: the tool call is right there in the message.
test "lift_message: a reply with messages and no choices still lifts" {
  let d = @openai.OpenAiDialect::make(model="test-model")
  let reply : Json = {
    "object": "chat.completion",
    "model": "openai/gpt-5.4-mini",
    "messages": [
      {
        "role": "assistant",
        "content": Json::null(),
        "tool_calls": [
          {
            "type": "function",
            "id": "call_1",
            "function": {
              "name": "read_file",
              "arguments": "{\"path\":\"a.txt\"}",
            },
          },
        ],
      },
    ],
    "usage": {
      "prompt_tokens": 102,
      "completion_tokens": 28,
      "prompt_tokens_details": { "cached_tokens": 0 },
    },
  }
  guard! @llm.Dialect::lift_message(d, reply)
    is AssistantMsg(content~, stop~, usage~, ..)
  // Stopped for a tool because it asked for one, which is what the missing
  // `finish_reason` would have said.
  assert_true(stop == @llm.StopReason::ToolUse)
  assert_eq(content.length(), 1)
  guard! content[0] is ToolCall(name~, ..)
  inspect(name, content="read_file")
  guard! usage is Some(u)
  assert_eq(u.input, 102)
}

///|
/// An empty turn, so a params test says only what it is about: the knobs.
fn params_ctx(params : @llm.LlmParams) -> @llm.LlmContext {
  { system: None, messages: [], tools: [], params, }
}

///|
/// The row a Cerebras-shaped model has: reasoning it cannot turn off, and a
/// ceiling well under what a caller might ask for.
fn oss_row() -> @llm.ModelInfo {
  {
    id: "gpt-oss-120b",
    api: None,
    reasoning: true,
    thinking_levels: [(Low, "low"), (Medium, "medium"), (High, "high")],
    supports_pro_mode: false,
    reasoning_contexts: [],
    input: [TextIn],
    context_window: 131_072,
    max_output_tokens: Some(40_960),
    cost: None,
  }
}

///|
/// The no-regression guarantee for every vendor on this shared mapping: a
/// caller who asks for nothing gets the body this dialect has always sent.
/// `LlmParams::default()` sets neither knob, so neither key appears.
test "openai lower_context: default params add nothing to the body" {
  let d = @openai.OpenAiDialect::make(model="gpt-5.4-mini")
  let body = @llm.Dialect::lower_context(
    d,
    params_ctx(@llm.LlmParams::default()),
  )
  guard! body is { "model": _, .. }
  assert_true(!(body is { "reasoning_effort": _, .. }))
  assert_true(!(body is { "max_completion_tokens": _, .. }))
}

///|
/// Why the rows were written. `Off` is a level `gpt-oss-120b` does not have,
/// and `clamp_effort` goes UP before it goes down, so the request carries the
/// least this model can do instead of a `none` it answers with a 400.
test "openai lower_context: effort clamps up when the model cannot stop" {
  let d = @openai.OpenAiDialect::make(model="gpt-oss-120b", info=oss_row())
  let asked = { ..@llm.LlmParams::default(), effort: Some(Off), }
  guard! @llm.Dialect::lower_context(d, params_ctx(asked))
    is { "reasoning_effort": String(name), .. }
  inspect(name, content="low")
}

///|
/// A model whose row says it does not reason is not asked to, however loudly
/// the caller sets the dial.
test "openai lower_context: a model that does not reason is not asked to" {
  let flat = { ..oss_row(), reasoning: false, }
  let d = @openai.OpenAiDialect::make(model="gpt-oss-120b", info=flat)
  let asked = { ..@llm.LlmParams::default(), effort: Some(High), }
  let body = @llm.Dialect::lower_context(d, params_ctx(asked))
  assert_true(!(body is { "reasoning_effort": _, .. }))
}

///|
/// The cap is the model's, not the caller's, and it is `max_completion_tokens`
/// — `max_tokens` is the deprecated spelling and sending both is an error.
test "openai lower_context: the output cap is clamped to the model's own" {
  let d = @openai.OpenAiDialect::make(model="gpt-oss-120b", info=oss_row())
  // -1 rather than a `fail`, so the assertion below names the number that
  // was wrong instead of the lookup that missed.
  fn cap_for(want : Int) -> Double {
    let asked = { ..@llm.LlmParams::default(), max_output_tokens: Some(want), }
    guard @llm.Dialect::lower_context(d, params_ctx(asked))
      is { "max_completion_tokens": Number(n, ..), .. } else {
      return -1.0
    }
    n
  }

  // Under the ceiling, the caller's number.
  assert_eq(cap_for(1024), 1024.0)
  // Over it, the model's.
  assert_eq(cap_for(999_999), 40_960.0)
  // And a cap too small to be meant is raised rather than refused.
  assert_eq(cap_for(1), 16.0)
}

///|
/// The reply that made this test exist: Cerebras answers a billing refusal
/// with the error object BARE, no `{"error": ...}` envelope, and the live
/// smoke run read it as "malformed reply: expected a chat completion" — which
/// pointed an operator at their mapping when the problem was their quota.
///
/// Verbatim from that run.
test "openai lift: a bare error object is an error, not a malformed reply" {
  let d = @openai.OpenAiDialect::make(model="gpt-oss-120b")
  let refusal : Json = {
    "message": "Payment required to access this resource. Visit your billing tab.",
    "type": "payment_required_error",
    "param": "quota",
    "code": "payment_required",
  }
  guard! @llm.Dialect::lift_message(d, refusal)
    is AssistantMsg(stop~, error~, content~, ..)
  assert_true(stop == @llm.StopReason::Errored)
  assert_eq(content.length(), 0)
  guard! error is Some(why)
  assert_true(why.contains("Payment required"))
}

///|
/// And the arm that keeps the one above from eating good replies: a chat
/// completion has no top-level string `message`, so it still lifts as text.
test "openai lift: a real completion is not mistaken for a bare error" {
  let d = @openai.OpenAiDialect::make(model="gpt-oss-120b")
  let reply : Json = {
    "choices": [{ "message": { "content": "pong" }, "finish_reason": "stop" }],
  }
  guard! @llm.Dialect::lift_message(d, reply)
    is AssistantMsg(content~, error~, ..)
  assert_true(error is None)
  guard! content[0] is AssistantText(text~, ..)
  inspect(text, content="pong")
}
