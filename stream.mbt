// One decoded step of a provider's stream. What a dialect makes of the bytes
// as they arrive, before there is a whole message to lift.

///|
/// A step of the reply, as the dialect decoded it (pi's
/// `AssistantMessageEvent`).
///
/// `content_index` is the block's position in the assistant message being
/// built — the same index `stream_finish` will hand back as `content[i]` — so
/// a consumer can key a partial render by it without knowing which wire
/// format produced it. Events for different blocks are not guaranteed
/// contiguous: a provider may interleave a tool call's arguments with the
/// text after it, which is exactly why the index is on every event and not
/// implied by order.
///
/// Nothing here mentions a transcript, a message id or a media type. Those
/// belong to whoever is embedding this, and a dialect that had to know them
/// could not be published on its own.
pub(all) enum StreamEvent {
  /// The reply has begun and named its model. First event, always.
  Start(model~ : String)
  TextStart(content_index~ : Int32)
  TextDelta(content_index~ : Int32, delta~ : String)
  TextEnd(content_index~ : Int32)
  ThinkingStart(content_index~ : Int32)
  ThinkingDelta(content_index~ : Int32, delta~ : String)
  ThinkingEnd(content_index~ : Int32)
  ToolCallStart(content_index~ : Int32, id~ : String, name~ : String)
  /// Arguments arrive as partial JSON TEXT — every provider streams them that
  /// way — so a consumer that wants them parsed waits for `stream_finish`.
  ToolCallDelta(content_index~ : Int32, delta~ : String)
  ToolCallEnd(content_index~ : Int32)
  /// The reply is complete. `stream_finish` still produces the message; this
  /// is what a live view draws before it arrives.
  Done(stop~ : StopReason, usage~ : Usage?)
  /// A provider error, which is data here as everywhere else: the call
  /// happened and the answer was a refusal, not an exception.
  Error(message~ : String)
} derive(Eq, Debug, ToJson)

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend StreamEvent with Eq::{not_equal, equal}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend StreamEvent with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend StreamEvent with ToJson::{to_json}
