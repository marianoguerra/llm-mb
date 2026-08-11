///|
/// The shape that separates this API from completions: the conversation is a
/// flat list of ITEMS, so one assistant turn with a text block and a tool
/// call is two entries, not one message with a `tool_calls` array beside its
/// content.
test "responses lower_context: one turn becomes several input items" {
  let d = @openai.OpenAiResponsesDialect::make(model="gpt-5.6-sol")
  assert_true(@llm.Dialect::id(d) == "openai-responses")
  let ctx : @llm.LlmContext = {
    system: Some("sys"),
    messages: [
      UserMsg(content=[UserText("hi")]),
      AssistantMsg(
        content=[
          AssistantText(text="on it", signature=None),
          @llm.AssistantBlock::ToolCall(
            id="call_0",
            name="request",
            arguments={ "verb": "READ", "uri": "file:///a" },
            signature=None,
          ),
        ],
        stop=@llm.StopReason::ToolUse,
        model="gpt-5.6-sol",
        response_id=None,
        usage=None,
        error=None,
      ),
      ToolResultMsg(
        tool_call_id="call_0",
        tool_name="request",
        content=[UserText("contents")],
        is_error=false,
      ),
    ],
    tools: [tool_decl("request")],
    params: @llm.LlmParams::default(),
  }
  let body = @llm.Dialect::lower_context(d, ctx)
  // The system prompt is `instructions`, not an item in the list.
  guard! body
    is {
      "model": String("gpt-5.6-sol"),
      "instructions": String("sys"),
      "input": Array(input),
      "tools": Array(tools),
      "store": False,
      ..
    }
  // user, assistant text, the call, the result — four items for three turns
  assert_eq(input.length(), 4)
  guard! input[0]
    is {
      "role": String("user"),
      "content": Array([{ "type": String("input_text"), .. }]),
      ..
    }
  guard! input[1]
    is {
      "type": String("message"),
      "role": String("assistant"),
      "content": Array([{ "type": String("output_text"), .. }]),
      ..
    }
  // the quirk shared with completions: arguments travel as a JSON *string*
  guard! input[2]
    is {
      "type": String("function_call"),
      "call_id": String("call_0"),
      "arguments": String(raw_args),
      ..
    }
  guard! @json.parse(raw_args) is { "verb": String("READ"), .. }
  guard! input[3]
    is {
      "type": String("function_call_output"),
      "call_id": String("call_0"),
      ..
    }
  // Tools are flat here — no {"type":"function","function":{...}} nesting.
  assert_eq(tools.length(), 1)
  guard! tools[0] is { "type": String("function"), "name": String(name), .. }
  inspect(name, content="request")
}

///|
/// The reasoning item is the model's chain across a tool call, and it is
/// opaque, so the whole item is the signature and goes back verbatim. It is
/// sealed to the model that produced it: after a model switch it is dropped
/// rather than handed to a model that cannot read it.
test "responses lower_context: a reasoning item replays verbatim" {
  fn ctx_with(model : String) -> @llm.LlmContext {
    {
      system: None,
      messages: [
        AssistantMsg(
          content=[
            Thinking(
              text="",
              signature=Some(
                (
                  {
                    "type": "reasoning",
                    "id": "rs_1",
                    "encrypted_content": "SEALED",
                  } : Json).stringify(),
              ),
              redacted=false,
            ),
            @llm.AssistantBlock::ToolCall(
              id="call_0",
              name="request",
              arguments={ "verb": "READ" },
              signature=None,
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

  let d = @openai.OpenAiResponsesDialect::make(model="gpt-5.6-luna")
  guard! @llm.Dialect::lower_context(d, ctx_with("gpt-5.6-luna"))
    is { "input": Array(kept), .. }
  assert_eq(kept.length(), 2)
  json_inspect(kept[0], content={
    "type": "reasoning",
    "id": "rs_1",
    "encrypted_content": "SEALED",
  })
  // A different model: the reasoning goes, the call stays.
  guard! @llm.Dialect::lower_context(d, ctx_with("gpt-5.4-mini"))
    is { "input": Array(dropped), .. }
  assert_eq(dropped.length(), 1)
  guard! dropped[0] is { "type": String("function_call"), .. }
  // Asking for the sealed content is what makes any of this replayable.
  guard! @llm.Dialect::lower_context(d, ctx_with("gpt-5.6-luna"))
    is { "include": Array([String("reasoning.encrypted_content")]), .. }
}

///|
test "responses lift_message: reasoning, text, call, usage, stop" {
  let d = @openai.OpenAiResponsesDialect::make()
  let reply : Json = {
    "id": "resp_1",
    "model": "gpt-5.6-luna",
    "status": "completed",
    "output": [
      {
        "type": "reasoning",
        "id": "rs_1",
        "encrypted_content": "SEALED",
        "summary": [{ "type": "summary_text", "text": "checking the file" }],
      },
      {
        "type": "message",
        "role": "assistant",
        "content": [{ "type": "output_text", "text": "reading it" }],
      },
      {
        "type": "function_call",
        "call_id": "call_9",
        "name": "request",
        "arguments": "{\"verb\": \"LIST\"}",
      },
    ],
    "usage": {
      "input_tokens": 100,
      "input_tokens_details": { "cached_tokens": 40 },
      "output_tokens": 7,
    },
  }
  guard! @llm.Dialect::lift_message(d, reply)
    is AssistantMsg(content~, stop~, usage~, model~, response_id~, ..)
  assert_eq(content.length(), 3)
  // the summary is what a reader gets; the item itself is the signature
  guard! content[0] is Thinking(text~, signature~, ..)
  inspect(text, content="checking the file")
  guard! signature is Some(raw)
  guard! @json.parse(raw) is { "encrypted_content": String("SEALED"), .. }
  guard! content[1] is AssistantText(text=answer, ..)
  inspect(answer, content="reading it")
  guard! content[2] is ToolCall(id~, name~, arguments~, ..)
  inspect(id, content="call_9")
  inspect(name, content="request")
  guard! arguments is { "verb": String("LIST"), .. }
  // There is no finish_reason on this API: wanting a tool is read off the
  // output that actually came back.
  assert_true(stop == @llm.StopReason::ToolUse)
  inspect(model, content="gpt-5.6-luna")
  assert_true(response_id is Some("resp_1"))
  // input_tokens counts the cached prefix, so it is not billed twice
  guard! usage is Some(u)
  assert_eq(u.input, 60)
  assert_eq(u.cache_read, 40)
  assert_eq(u.output, 7)
}

///|
test "responses lift: status maps to a stop reason" {
  let d = @openai.OpenAiResponsesDialect::make()
  fn lift_stop(reply : Json) -> @llm.StopReason raise {
    guard! @llm.Dialect::lift_message(d, reply) is AssistantMsg(stop~, ..)
    stop
  }

  let answered : Json = {
    "status": "completed",
    "output": [
      {
        "type": "message",
        "content": [{ "type": "output_text", "text": "hi" }],
      },
    ],
  }
  assert_true(lift_stop(answered) == @llm.StopReason::EndTurn)
  assert_true(
    lift_stop({
      "status": "incomplete",
      "incomplete_details": { "reason": "max_output_tokens" },
      "output": [],
    }) ==
    @llm.StopReason::MaxTokens,
  )
  assert_true(
    lift_stop({ "status": "cancelled", "output": [] }) ==
    @llm.StopReason::Aborted,
  )
  // A failed response says why on the response itself, not in the top-level
  // error shape — so it lifts as an errored message carrying the reason.
  guard! @llm.Dialect::lift_message(d, {
      "status": "failed",
      "output": [],
      "error": { "message": "the model gave up" },
    })
    is AssistantMsg(stop~, error~, ..)
  assert_true(stop == @llm.StopReason::Errored)
  assert_true(error is Some("the model gave up"))
}

///|
test "responses lift: api errors are data, malformed replies raise" {
  let d = @openai.OpenAiResponsesDialect::make()
  guard! @llm.Dialect::lift_message(d, {
      "error": { "message": "rate limited" },
    })
    is AssistantMsg(stop~, error~, ..)
  assert_true(stop == @llm.StopReason::Errored)
  assert_true(error is Some("rate limited"))
  try @llm.Dialect::lift_message(d, { "nope": true }) catch {
    @llm.DialectError::MalformedReply(_) => ()
  } noraise {
    _ => fail("expected a malformed reply to raise")
  }
}

///|
/// Unlike completions there is no plain-string shorthand: user content is a
/// typed list either way, and an image is a data URI under `input_image`.
test "responses lower_context: user content is always typed parts" {
  let d = @openai.OpenAiResponsesDialect::make(model="test-model")
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
  guard! @llm.Dialect::lower_context(d, ctx) is { "input": Array([u]), .. }
  json_inspect(u, content={
    "role": "user",
    "content": [
      {
        "type": "input_image",
        "detail": "auto",
        "image_url": "data:image/png;base64,iVBORw==",
      },
      { "type": "input_text", "text": "what colour?" },
    ],
  })
}

///|
/// An empty turn, so a test can say only what it is about: the knobs.
fn with_params(params : @llm.LlmParams) -> @llm.LlmContext {
  { system: None, messages: [], tools: [], params }
}

///|
fn lower_with(model : String, params : @llm.LlmParams) -> Json {
  @llm.Dialect::lower_context(
    @openai.OpenAiResponsesDialect::make(model~),
    with_params(params),
  )
}

///|
/// Effort is a portable dial and every model has its own levels: `max`
/// arrived with the gpt-5.6 family, gpt-5.4 stops at `xhigh`, gpt-5.5 has no
/// `minimal`. A level a model lacks is clamped to its nearest one, upward
/// first — a model asked to think harder than it can should think as hard as
/// it can, not less than it was asked.
test "responses lower_context: effort is clamped to the model's own levels" {
  fn effort_of(model : String, level : @llm.ThinkingLevel) -> String {
    guard lower_with(model, { ..@llm.LlmParams::default(), effort: Some(level) })
      is { "reasoning": { "effort": String(name), .. }, .. } else {
      return "<absent>"
    }
    name
  }

  inspect(effort_of("gpt-5.6-sol", Max), content="max")
  inspect(effort_of("gpt-5.6", Max), content="max") // the alias routes to Sol
  inspect(effort_of("gpt-5.4-mini", Max), content="xhigh") // `max` is 5.6-only
  inspect(effort_of("gpt-5.1", Max), content="high") // and 5.1 stops earlier
  inspect(effort_of("gpt-5.6-sol", Minimal), content="low") // 5.6 dropped it
  inspect(effort_of("gpt-5", Minimal), content="minimal") // gpt-5 still has it
  inspect(effort_of("o3", Off), content="low") // no way to turn it off here
  inspect(effort_of("gpt-5", Off), content="minimal") // nor here
  inspect(effort_of("gpt-5.6-sol", Off), content="none")
  // A model that does not reason is never asked to.
  inspect(effort_of("gpt-4.1", High), content="<absent>")
  // A model this table has never heard of is asked for what was wanted.
  inspect(effort_of("gpt-6-something", XHigh), content="xhigh")
}

///|
/// Asking for nothing is not the same as asking for `none`: no effort means
/// say nothing and let the model do what it does, while `none` turns
/// reasoning off — and on this family that takes function tools with it.
test "responses lower_context: no effort asked for sends no reasoning block" {
  guard! lower_with("gpt-5.6-sol", @llm.LlmParams::default()) is Object(fields)
  assert_true(fields.get("reasoning") is None)
  // The chain still comes back, so a tool call can replay it.
  assert_true(fields.get("include") is Some(_))
  // Turned off, there is no chain to ask for.
  guard! lower_with("gpt-5.6-sol", {
      ..@llm.LlmParams::default(),
      effort: Some(Off),
    })
    is Object(off)
  assert_true(off.get("include") is None)
}

///|
/// Pro mode is a gpt-5.6 feature, and reasoning kept across *all* turns
/// arrived one release earlier. On a model without them the knob is dropped
/// rather than sent — the same rule as a signature the dialect cannot
/// replay, and the reason is the same: the request would be rejected.
test "responses lower_context: pro mode and persisted reasoning are dropped where absent" {
  let asked : @llm.LlmParams = {
    ..@llm.LlmParams::default(),
    effort: Some(High),
    pro_mode: true,
    reasoning_context: Some(AllTurns),
    reasoning_summary: true,
  }
  guard! lower_with("gpt-5.6-sol", asked) is { "reasoning": reasoning, .. }
  json_inspect(reasoning, content={
    "effort": "high",
    "summary": "auto",
    "mode": "pro",
    "context": "all_turns",
  })
  // gpt-5.5 keeps reasoning across turns but has no pro mode.
  guard! lower_with("gpt-5.5", asked) is { "reasoning": older, .. }
  json_inspect(older, content={
    "effort": "high",
    "summary": "auto",
    "context": "all_turns",
  })
  // gpt-5.2 has neither: it takes `auto` and `current_turn` only.
  guard! lower_with("gpt-5.2", asked) is { "reasoning": oldest, .. }
  json_inspect(oldest, content={ "effort": "high", "summary": "auto" })
  // ...but the setting it does have still travels.
  guard! lower_with("gpt-5.2", { ..asked, reasoning_context: Some(CurrentTurn) })
    is { "reasoning": { "context": String(kept), .. }, .. }
  inspect(kept, content="current_turn")
}

///|
/// The cap is the caller's, bounded by the model's — and never below the 16
/// the API refuses, which is a mistake rather than an intent.
test "responses lower_context: the output cap is clamped to the model's" {
  fn cap_of(model : String, want : Int) -> Json {
    guard! lower_with(model, {
        ..@llm.LlmParams::default(),
        max_output_tokens: Some(want),
      })
      is { "max_output_tokens": cap, .. }
    cap
  }

  json_inspect(cap_of("gpt-5.6-sol", 32_000), content=32_000)
  json_inspect(cap_of("gpt-5.6-sol", 500_000), content=128_000)
  json_inspect(cap_of("gpt-5.6-sol", 1), content=16)
  // Unknown model, unknown ceiling: what was asked for.
  json_inspect(cap_of("gpt-6-something", 500_000), content=500_000)
  guard! lower_with("gpt-5.6-sol", @llm.LlmParams::default()) is Object(fields)
  assert_true(fields.get("max_output_tokens") is None)
}

///|
/// The cache key is the session id, so a session keeps hitting the prefix
/// the provider cached for it. It is capped at 64 characters counted in
/// codepoints — cutting bytes could split one in half.
test "responses lower_context: prompt caching travels with the session" {
  let long_key = "é".repeat(100)
  guard! lower_with("gpt-5.6-sol", {
      ..@llm.LlmParams::default(),
      cache_key: Some(long_key),
      cache_retention: LongCache,
    })
    is {
      "prompt_cache_key": String(key),
      "prompt_cache_retention": String(retention),
      ..
    }
  assert_eq(key.iter().count(), 64)
  inspect(retention, content="24h")
  // Short retention is the provider's own default: the key travels, the
  // retention field does not.
  guard! lower_with("gpt-5.6-sol", {
      ..@llm.LlmParams::default(),
      cache_key: Some("web-1"),
    })
    is Object(short)
  assert_true(short.get("prompt_cache_key") is Some(_))
  assert_true(short.get("prompt_cache_retention") is None)
  // Caching off: neither.
  guard! lower_with("gpt-5.6-sol", {
      ..@llm.LlmParams::default(),
      cache_key: Some("web-1"),
      cache_retention: NoCache,
    })
    is Object(none)
  assert_true(none.get("prompt_cache_key") is None)
}

///|
/// `phase` and the item id are what OpenAI asks to have handed back on every
/// assistant message — dropping the phase degrades the answer, and the id is
/// what the reasoning it produced is paired with. Neither belongs in the IR,
/// so they ride in the block's signature and come back out on the next turn.
test "responses: an assistant message replays its id and phase" {
  let d = @openai.OpenAiResponsesDialect::make(model="gpt-5.6-sol")
  guard! @llm.Dialect::lift_message(d, {
      "status": "completed",
      "model": "gpt-5.6-sol",
      "output": [
        {
          "type": "message",
          "id": "msg_7",
          "phase": "final_answer",
          "content": [{ "type": "output_text", "text": "done" }],
        },
      ],
    })
    is AssistantMsg(content=[AssistantText(signature~, ..)], ..)
  guard! signature is Some(raw)
  json_inspect(@json.parse(raw), content={
    "id": "msg_7",
    "phase": "final_answer",
    "v": 1,
  })
  fn replay(model : String) -> Json {
    let ctx : @llm.LlmContext = {
      system: None,
      messages: [
        AssistantMsg(
          content=[AssistantText(text="done", signature=Some(raw))],
          stop=@llm.StopReason::EndTurn,
          model~,
          response_id=None,
          usage=None,
          error=None,
        ),
      ],
      tools: [],
      params: @llm.LlmParams::default(),
    }
    guard! @llm.Dialect::lower_context(d, ctx) is { "input": Array([m]), .. }
    m
  }

  guard! replay("gpt-5.6-sol")
    is { "id": String(id), "phase": String(phase), .. }
  inspect(id, content="msg_7")
  inspect(phase, content="final_answer")
  // After a model switch they are gone: the id was handed out to another
  // model, and a phase describes how that one was working through the turn.
  guard! replay("gpt-5.4-mini") is Object(switched)
  assert_true(switched.get("id") is None)
  assert_true(switched.get("phase") is None)
}

///|
/// `input_tokens` counts the whole prefix, cached and freshly cached alike,
/// so both come out of the fresh-input figure. Cache writes are their own
/// line item since the gpt-5.6 family, the first here to charge for them.
test "responses lift: cache writes are counted apart from fresh input" {
  let d = @openai.OpenAiResponsesDialect::make(model="gpt-5.6-sol")
  guard! @llm.Dialect::lift_message(d, {
      "status": "completed",
      "output": [],
      "usage": {
        "input_tokens": 1000,
        "input_tokens_details": {
          "cached_tokens": 600,
          "cache_write_tokens": 300,
        },
        "output_tokens": 20,
      },
    })
    is AssistantMsg(usage~, ..)
  guard! usage is Some(u)
  assert_eq(u.input, 100)
  assert_eq(u.cache_read, 600)
  assert_eq(u.cache_write, 300)
  assert_eq(u.output, 20)
}
