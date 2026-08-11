// Stage 2 of the lowering: dialect-agnostic LlmContext -> provider wire
// format, one impl per provider protocol, quirks inside the impl and never
// in the IR. `raise` is a keyword, so the inverse direction is `lift`.

///|
pub fn StreamState::new() -> StreamState {
  { chunks: [] }
}

///|
/// Append a chunk, returning a new state (pure — the shell owns the loop).
pub fn StreamState::push(self : StreamState, chunk : String) -> StreamState {
  let chunks = self.chunks.copy()
  chunks.push(chunk)
  { chunks, }
}

///|
/// The accumulated raw body so far.
pub fn StreamState::text(self : StreamState) -> String {
  self.chunks.join("")
}

///|
/// Default: this dialect does not name a model, and whoever needs one falls
/// back to whatever it was configured with.
impl Dialect with fn model(_self : Self) -> String {
  ""
}

///|
/// Default: fresh accumulator.
impl Dialect with fn stream_init(_self : Self) -> StreamState {
  StreamState::new()
}

///|
/// Default: buffer the chunk, emit no incremental events.
impl Dialect with fn stream_feed(
  _self : Self,
  state : StreamState,
  chunk~ : String,
) -> (StreamState, Array[StreamEvent]) raise DialectError {
  (state.push(chunk), [])
}

///|
/// Default: parse the accumulated body as one JSON reply and lift it.
impl Dialect with fn stream_finish(self : Self, state : StreamState) -> ContextMessage raise DialectError {
  let text = state.text()
  let json = @json.parse(text) catch {
    _ => raise DialectError::MalformedReply("stream body was not valid JSON")
  }
  self.lift_message(json)
}
