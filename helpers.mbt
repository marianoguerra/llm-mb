// Helpers shared by the provider dialects: the parts of lifting/lowering
// that are genuinely provider-independent. Anything keyed by provider JSON
// key names stays inside each dialect.

///|
pub impl Show for DialectError with fn output(self, logger) {
  match self {
    MalformedReply(msg) => logger.write_string("malformed reply: \{msg}")
  }
}

///|
/// Provider API errors are data on the message, never exceptions (pi
/// convention). Matches the `{"error": {"message": ...}}` shape all four
/// providers answer with (Anthropic wraps it in `{"type": "error", ...}`,
/// which this pattern also matches).
pub fn api_error(reply : Json, model~ : String) -> ContextMessage? {
  guard reply is { "error": { "message": String(message), .. }, .. } else {
    return None
  }
  Some(
    AssistantMsg(
      content=[],
      stop=Errored,
      model~,
      response_id=None,
      usage=None,
      error=Some(message),
    ),
  )
}

///|
/// What an image degrades to where a wire path takes text only — tool-result
/// content, which no provider models as an image block. User turns carry
/// images natively (see each dialect's user-content mapping).
fn image_marker(media_type : String) -> String {
  "[image \{media_type} omitted]"
}

///|
/// Flatten user blocks to one text: text passes through, images degrade to
/// a marker (v1 wire formats are text-first).
pub fn user_text(blocks : Array[UserBlock]) -> String {
  blocks
  .map(block => {
    match block {
      UserText(text) => text
      UserImage(media_type~, ..) => image_marker(media_type)
    }
  })
  .join("\n\n")
}

///|
/// Which model answered, and what the provider called the call.
///
/// The tail of every `lift_message`, and identical in all of them: all four
/// providers name the model in `model` and the call in `id`, at the top level
/// of the reply. `fallback` is what the dialect was configured with, for a
/// provider that echoes neither.
///
/// This is here and the `usage` block above it is not, because usage is keyed
/// by provider JSON key names — `input_tokens` against `prompt_tokens` — and
/// this is not keyed by anything. That is the line the header draws.
pub fn reply_identity(reply : Json, fallback~ : String) -> (String, String?) {
  let model = match reply {
    { "model": String(m), .. } => m
    _ => fallback
  }
  let response_id = match reply {
    { "id": String(id), .. } => Some(id)
    _ => None
  }
  (model, response_id)
}
