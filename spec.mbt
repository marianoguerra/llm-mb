// Stage 0 of the LLM lowering: the dialect-agnostic IR, modeled on pi.dev's
// `Context`. Both directions of a turn are pure functions of this, which is
// what makes switching model mid-session mean "pass the same LlmContext to a
// different Dialect" and nothing else.

///|
pub(all) enum UserBlock {
  UserText(String)
  UserImage(media_type~ : String, data~ : Bytes)
} derive(Debug, ToJson)

///|
/// `signature` on all three is the provider's opaque proof that this block is
/// the model's own output, replayed verbatim on the next turn or dropped.
/// Anthropic signs thinking; Gemini 3 signs whatever part carried the
/// reasoning — including tool calls, where it is mandatory: a functionCall
/// replayed without its thoughtSignature is a 400. It survives whatever
/// round-trip the embedding application puts the message through, and a
/// dialect only replays a signature its own model produced.
pub(all) enum AssistantBlock {
  AssistantText(text~ : String, signature~ : String?)
  Thinking(text~ : String, signature~ : String?, redacted~ : Bool)
  ToolCall(
    id~ : String,
    name~ : String,
    arguments~ : Json,
    signature~ : String?
  )
} derive(Debug, ToJson)

///|
/// pi: stop | length | toolUse | error | aborted — errors are data, never
/// exceptions.
pub(all) enum StopReason {
  EndTurn
  MaxTokens
  ToolUse
  Errored
  Aborted
} derive(Eq, Debug, ToJson)

///|
pub(all) struct Usage {
  input : Int
  output : Int
  cache_read : Int
  cache_write : Int
} derive(Eq, Debug, ToJson)

///|
#declaration_only
pub fn Usage::make(
  input~ : Int,
  output~ : Int,
  cache_read? : Int = 0,
  cache_write? : Int = 0,
) -> Usage {
  ...
}

///|
/// Recover token usage persisted alongside a message.
#declaration_only
pub fn Usage::from_json(value : Json) -> Usage? {
  ...
}

///|
pub(all) enum ContextMessage {
  UserMsg(content~ : Array[UserBlock])
  AssistantMsg(
    content~ : Array[AssistantBlock],
    stop~ : StopReason,
    model~ : String, // provenance survives mid-session model switches
    response_id~ : String?,
    usage~ : Usage?,
    error~ : String?
  )
  ToolResultMsg(
    tool_call_id~ : String,
    tool_name~ : String,
    content~ : Array[UserBlock],
    is_error~ : Bool
  )
} derive(Debug, ToJson)

///|
pub(all) struct ToolDecl {
  name : String
  description : String
  input_schema : Json
} derive(Debug, ToJson)

///|
/// How hard the model should think, as a dial that means the same thing on
/// every provider (pi's ThinkingLevel). Ordered low to high: a dialect maps
/// it to whatever its own model spells, and clamps to the nearest level that
/// model actually has — the levels are not the same everywhere, and a
/// request for one a model lacks should land next to it rather than 400.
pub(all) enum ThinkingLevel {
  Off
  Minimal
  Low
  Medium
  High
  XHigh
  Max
} derive(Eq, Compare, Debug, ToJson)

///|
/// How much of the earlier turns' reasoning the provider may reuse
/// (OpenAI's `reasoning.context`, new with the gpt-5.6 family). Distinct
/// from replaying reasoning items ourselves, which every turn already does:
/// this asks the provider to render its own retained chain into the context.
pub(all) enum ReasoningContext {
  AutoContext
  CurrentTurn
  AllTurns
} derive(Eq, Debug, ToJson)

///|
/// How long a provider may keep the cached prompt prefix: not at all, its
/// own default (minutes, in memory), or the extended tier.
pub(all) enum CacheRetention {
  NoCache
  ShortCache
  LongCache
} derive(Eq, Debug, ToJson)

///|
/// The knobs a turn is asked for, dialect-agnostic on purpose: they travel
/// with the LlmContext so that switching model mid-session keeps meaning
/// "pass the same context to a different Dialect". A dialect maps what its
/// API can express and silently drops the rest — the same rule as a
/// signature it cannot replay.
pub(all) struct LlmParams {
  // None means "say nothing about reasoning", i.e. the model's own default.
  // Off is a different thing: it asks for reasoning to be turned off.
  effort : ThinkingLevel?
  pro_mode : Bool
  reasoning_context : ReasoningContext?
  // Reasoning summaries are opt-in and cost tokens; the chain replays either
  // way, since what replays is the opaque item and not the summary.
  reasoning_summary : Bool
  max_output_tokens : Int?
  // Usually the session id: a stable key is what lets the provider find the
  // prefix it cached for this conversation.
  cache_key : String?
  cache_retention : CacheRetention
} derive(Debug, ToJson)

///|
/// Nothing requested: no reasoning block, no output cap, caching left at the
/// provider's default. Keeping `effort` None rather than Off matters — Off
/// would quietly turn reasoning off for every existing session.
#declaration_only
pub fn LlmParams::default() -> LlmParams {
  ...
}

///|
/// Parse a level from configuration; None for anything unrecognised, so a
/// typo falls back to the default rather than failing a run.
#declaration_only
pub fn ThinkingLevel::parse(s : String) -> ThinkingLevel? {
  ...
}

///|
/// Parse a retention setting: "none" | "short" | "long".
#declaration_only
pub fn CacheRetention::parse(s : String) -> CacheRetention? {
  ...
}

///|
/// Parse a reasoning-context setting: "auto" | "current_turn" | "all_turns".
#declaration_only
pub fn ReasoningContext::parse(s : String) -> ReasoningContext? {
  ...
}

///|
/// One turn's whole input: what the model is told, what it has said, what it
/// may call, and how hard it should think.
pub(all) struct LlmContext {
  system : String?
  messages : Array[ContextMessage]
  tools : Array[ToolDecl]
  params : LlmParams // per-turn knobs, mapped per dialect
} derive(Debug, ToJson)

// --- what a model can be asked for ------------------------------------------

///|
/// What a turn may carry INTO a model. Nothing reads this yet; it is here
/// because a catalog that cannot say "this one has no vision" makes the
/// caller find out from a 400.
pub(all) enum Modality {
  TextIn
  ImageIn
} derive(Eq, Debug, ToJson)

///|
/// USD per million tokens. Separate from `Usage` on purpose: usage is what a
/// call actually spent, this is what the provider charges, and the two are
/// updated by completely different people.
pub(all) struct Cost {
  input : Double
  output : Double
  cache_read : Double
  cache_write : Double
} derive(Eq, Debug, ToJson)

///|
/// One model's request-side capabilities (pi's `Model`).
///
/// `thinking_levels` maps the portable dial to this model's own spelling
/// (pi's `thinkingLevelMap`); a level absent from the list does not exist
/// here and clamps to the nearest one that does — asking for one a model
/// lacks is a 400, not a downgrade. `reasoning_contexts` and
/// `supports_pro_mode` are pass/drop rather than clamp: there is no nearly-pro.
///
/// Data, not code, so a new model is a row. That is how pi.dev does it and
/// it is why `Registry::with_provider` can add a vendor without a code path.
pub(all) struct ModelInfo {
  id : String
  /// Which wire protocol answers for THIS model, when it is not the one its
  /// provider names. Mixed-API providers are the reason this is per-model at
  /// all — pi's Copilot serves some models as `anthropic-messages` and others
  /// as `openai-completions`. None means "whatever the provider says".
  api : String?
  reasoning : Bool
  thinking_levels : Array[(ThinkingLevel, String)]
  supports_pro_mode : Bool
  reasoning_contexts : Array[ReasoningContext]
  input : Array[Modality]
  context_window : Int
  // None where the ceiling is unknown — a model this table has not met is
  // asked for whatever the caller wanted rather than being silently trimmed.
  max_output_tokens : Int?
  cost : Cost?
} derive(Debug, ToJson)

///|
/// What to assume about a model nobody wrote a row for: reasoning on, every
/// level passed through under its portable name, no output cap.
///
/// The bet is that a new model is a superset of an old one. A 400 naming the
/// parameter is a better failure than silently thinking less than it was
/// asked to.
#declaration_only
pub fn ModelInfo::permissive(id : String) -> ModelInfo {
  ...
}

///|
/// This model's spelling of `level`, or the nearest level it does have.
/// Nearest means upward first — a model asked to think harder than it can
/// should think as hard as it can, not less than it was asked — and only
/// downward when there is nothing above (pi's clampThinkingLevel). None
/// when the model has no reasoning dial at all.
#declaration_only
pub fn ModelInfo::clamp_effort(
  self : ModelInfo,
  level : ThinkingLevel,
) -> String? {
  ...
}

///|
/// Whether this model takes that persisted-reasoning setting. Unlike effort
/// there is nothing to clamp to: asking a model that only keeps the current
/// turn to keep all of them is not a smaller version of the same request, so
/// it is dropped and the provider's own default applies.
#declaration_only
pub fn ModelInfo::allows_context(
  self : ModelInfo,
  context : ReasoningContext,
) -> Bool {
  ...
}

///|
/// Whether a turn may put that kind of block in front of this model.
#declaration_only
pub fn ModelInfo::accepts(self : ModelInfo, modality : Modality) -> Bool {
  ...
}

// --- stage 2: the dialect ---------------------------------------------------

///|
pub(all) suberror DialectError {
  MalformedReply(String)
} derive(Debug, ToJson)

///|
/// Accumulator threaded through incremental decoding. A dialect that decodes
/// true per-chunk SSE keeps partial-block state here; the default encoding
/// simply buffers raw chunks and lifts the whole reply at `stream_finish`.
pub(all) struct StreamState {
  chunks : Array[String]
} derive(Debug)

///|
#declaration_only
pub fn StreamState::new() -> StreamState {
  ...
}

///|
/// Append a chunk, returning a new state (pure — the shell owns the loop).
#declaration_only
pub fn StreamState::push(self : StreamState, chunk : String) -> StreamState {
  ...
}

///|
/// The accumulated raw body so far.
#declaration_only
pub fn StreamState::text(self : StreamState) -> String {
  ...
}

///|
/// One provider protocol, both directions.
///
/// Both are pure: switching LLMs mid-session is passing the same LlmContext
/// to a different Dialect. Streaming decode (stream_*) keeps SSE framing
/// knowledge inside the dialect, so a deployment can put the dialect on
/// either side of a network boundary — the transport stays a byte pump that
/// never learns which provider is on the other end.
pub(open) trait Dialect {
  fn id(Self) -> String // "anthropic-messages", "openai-completions", ...
  /// Which model of that protocol this one speaks to — "gemini-3.6-flash".
  ///
  /// Three of the four dialects put it in the body they lower, so nothing
  /// outside them needed to know it. Gemini's endpoint carries it in the URL
  /// instead, so whoever builds that URL has to be told, and the dialect is
  /// the one thing that was handed a model at all (`make(model?)`).
  ///
  /// Empty means "this dialect does not name one", which is what a test
  /// double and the default below say.
  fn model(Self) -> String = _
  fn lower_context(Self, LlmContext) -> Json // provider request body
  fn lift_message(Self, Json) -> ContextMessage raise DialectError
  // incremental lifting; default impls buffer + lift at finish. A dialect
  // may override to emit real per-block deltas.
  fn stream_init(Self) -> StreamState = _
  fn stream_feed(Self, StreamState, chunk~ : String) -> (
    StreamState,
    Array[StreamEvent],
  ) raise DialectError = _
  fn stream_finish(Self, StreamState) -> ContextMessage raise DialectError = _
}

// --- the transport ----------------------------------------------------------

///|
/// Sends an already-lowered provider body to a NAMED target and pumps raw
/// chunks back. It never inspects or rewrites the body and never learns the
/// dialect.
///
/// `target` is a name, not an endpoint — whoever holds the credential
/// resolves it in their own table. That is what lets the same trait be an
/// HTTP client with a key in it and a page posting to a relay that has one.
///
/// CONTINUATIONS, not `async`, and that is not a style choice: a browser
/// cannot have async — `moonbitlang/async`'s event loop is unimplemented for
/// wasm-gc, and an async function cannot be called from the plain exported
/// functions a page starts from. A trait only one of the two sides could
/// implement would not be a seam. The native side pays for this by parking
/// on a semaphore, which is the cheaper half of the trade.
///
/// `on_error` is for a call that never happened. A provider answering 429 or
/// 400 answers with a BODY, and that body is a chunk: errors are data, and
/// the dialect is what reads them.
pub(open) trait LlmTransport {
  fn send(
    Self,
    handle~ : String,
    target~ : String,
    body~ : Json,
    headers~ : Map[String, String], // traceparent, per-call overrides
    on_chunk~ : (String) -> Unit,
    on_done~ : () -> Unit,
    on_error~ : (String) -> Unit,
  ) -> Unit
  /// Stop the call started under `handle`, if it is still running.
  ///
  /// Nothing comes back: whoever asked has already stopped waiting, and a
  /// call that had finished is not a failure to report. Default: nothing,
  /// for a transport with no way to.
  fn abort(Self, handle~ : String) -> Unit = _
}

///|
/// A transport that hands the call to something else holding the credential
/// — a page posting to its own server, a worker posting to a gateway.
///
/// `post` is `(handle, target, body as text, ok, err)`: the relay is told
/// which target to resolve and given bytes to forward, and answers with the
/// whole reply. That it takes TEXT rather than Json is the point — a relay
/// is not supposed to parse what it is relaying.
///
/// `ok` delivering the whole body is what a buffering relay does. When one
/// streams, this is the line that changes and nothing above it does: the
/// dialect already decodes incrementally.
pub(all) struct RelayTransport {
  post : (String, String, String, (String) -> Unit, (String) -> Unit) -> Unit
  stop : (String) -> Unit
}

///|
/// A relay whose calls cannot be stopped answers `stop` with nothing, which
/// is honest: a turn that keeps streaming after a cancel keeps costing
/// tokens nobody will read, but pretending to abort would hide that.
#declaration_only
pub fn RelayTransport::make(
  post~ : (String, String, String, (String) -> Unit, (String) -> Unit) -> Unit,
  stop? : (String) -> Unit,
) -> RelayTransport {
  ...
}

// --- the registry -----------------------------------------------------------

///|
/// How a provider is authenticated.
///
/// The credential is never here. A registry is DATA — it compiles into a page
/// — and data that names an environment variable is safe to ship where its
/// value is not.
pub(all) enum AuthStyle {
  /// `authorization: Bearer <key>` — openai, openrouter, most compatibles.
  BearerHeader
  /// A named header carrying the raw key — anthropic's `x-api-key`.
  KeyHeader(String)
  /// A query parameter on the endpoint — gemini's `?key=`.
  KeyQuery(String)
  /// A local endpoint that wants no credential at all.
  NoAuth
} derive(Eq, Debug, ToJson)

///|
/// One wire protocol, and how to build a dialect that speaks it.
///
/// `make` is what replaces a `match provider` somewhere: a new API is a value
/// handed to a registry, not an arm somebody has to find. `caps` is what this
/// API assumes about a model nobody wrote a row for — it lives with the
/// dialect that reads it, because that is the code a wrong assumption breaks.
///
/// Closures, so this is the one type here that derives nothing. Everything a
/// proxy might want to hand a page — `ProviderSpec`, `ModelInfo` — is data
/// and does.
pub(all) struct ApiSpec {
  id : String // "anthropic-messages", "openai-responses", ...
  make : (ModelInfo) -> &Dialect
  caps : (String) -> ModelInfo
}

///|
/// One provider: an endpoint, a credential shape, and the models it offers.
///
/// All data. That is the point — pi's `registerProvider({baseUrl, apiKey:
/// "$MY_KEY", api: "openai-completions", models: [...]})` adds an
/// OpenAI-compatible vendor with no code at all, and this is the same bet:
/// a new provider is a row.
///
/// `models` is both the offer and the capability table. Two arrays that had
/// to agree is what a guard test used to be for.
pub(all) struct ProviderSpec {
  id : String // "openai" — what a label says before the colon
  name : String // "OpenAI" — what a person reads
  api : String // an ApiSpec id, unless a ModelInfo overrides it
  /// `{model}` is substituted where the endpoint carries the model instead of
  /// the body. Gemini is the only one today, and it is why a target that
  /// drops the model reaches a different one than the caller lowered for.
  endpoint : String
  auth : AuthStyle
  key_env : String // the NAME. Never the value.
  model_env : String
  default_model : String
  models : Array[ModelInfo]
  /// Everything every call to this provider carries: content-type, an
  /// `anthropic-version`, a `HTTP-Referer` a vendor asks for.
  headers : Map[String, String]
  /// What OpenTelemetry calls this provider (`gen_ai.provider.name`), and
  /// where it is.
  telemetry_name : String
  server_address : String
} derive(Debug)

///|
/// Every API and provider a build knows.
///
/// A VALUE threaded by whoever holds it, not a mutable global: two tests can
/// hold different registries, a caller can add a provider without touching
/// the package that ships the defaults, and nothing is initialized behind
/// anybody's back.
pub(all) struct Registry {
  apis : Map[String, ApiSpec]
  providers : Array[ProviderSpec]
}

///|
#declaration_only
pub fn Registry::of(
  apis : Array[ApiSpec],
  providers : Array[ProviderSpec],
) -> Registry {
  ...
}

///|
/// This registry with one more provider — how a caller adds an
/// OpenAI-compatible vendor without forking the catalog. Replaces a provider
/// of the same id, so it is also how one is overridden.
#declaration_only
pub fn Registry::with_provider(
  self : Registry,
  spec : ProviderSpec,
) -> Registry {
  ...
}

///|
/// This registry with one more wire protocol, for a dialect that ships
/// outside the package holding the defaults.
#declaration_only
pub fn Registry::with_api(self : Registry, spec : ApiSpec) -> Registry {
  ...
}

///|
#declaration_only
pub fn Registry::api(self : Registry, id : String) -> ApiSpec? {
  ...
}

///|
#declaration_only
pub fn Registry::provider(self : Registry, id : String) -> ProviderSpec? {
  ...
}

///|
/// Split a `"provider:model"` label. An empty model means "whichever one
/// that provider defaults to".
#declaration_only
pub fn split_label(label : String) -> (String, String) {
  ...
}

///|
/// What `provider` can be asked for about `model`: its own row if it has
/// one, else what the API assumes about a model it has not met. None only
/// when the provider itself is unknown.
#declaration_only
pub fn Registry::model_info(
  self : Registry,
  provider~ : String,
  model~ : String,
) -> ModelInfo? {
  ...
}

///|
/// Every `"provider:model"` label, in table order — a selector's options.
#declaration_only
pub fn Registry::labels(self : Registry) -> Array[String] {
  ...
}

///|
/// The dialect behind a `"provider:model"` label.
///
/// None for a provider this build does not know. A caller that gets None has
/// been offered a model by something speaking a protocol it cannot lower for,
/// which is worth saying out loud rather than defaulting into.
#declaration_only
pub fn Registry::dialect_of(self : Registry, label : String) -> &Dialect? {
  ...
}

///|
/// The first provider speaking `api`, for a target that names a protocol
/// rather than a vendor.
#declaration_only
pub fn Registry::provider_for_api(
  self : Registry,
  api : String,
) -> ProviderSpec? {
  ...
}

///|
/// Where a call goes and what it carries, given the credential.
///
/// Pure: the caller read the environment, this does the arithmetic —
/// substituting `{model}`, placing the key per `auth`, merging `headers`.
///
/// A model the provider does not LIST is an `Err` naming it. The name is
/// interpolated into a URL, and the list is exactly what `labels()` offered,
/// so nothing a selector can pick is refused and nothing else is believed.
/// An empty `model` takes the provider's default.
#declaration_only
pub fn Registry::endpoint(
  self : Registry,
  provider~ : String,
  model~ : String,
  key~ : String,
) -> Result[(String, Map[String, String]), String] {
  ...
}

///|
/// Provider API errors are data on the message, never exceptions. Matches
/// the wrapped `{"error": {"message": ...}}` shape, and the bare one an
/// OpenAI-compatible vendor may answer with instead.
#declaration_only
pub fn api_error(reply : Json, model~ : String) -> ContextMessage? {
  ...
}

///|
/// What an image degrades to where a wire path takes text only. User turns
/// carry images natively on every dialect that supports them; this is what
/// is left — tool-result content, which no provider models as an image
/// block.
#declaration_only
fn image_marker(media_type : String) -> String {
  ...
}

///|
/// Flatten user blocks to one text: text passes through, images degrade to
/// `image_marker`.
#declaration_only
pub fn user_text(blocks : Array[UserBlock]) -> String {
  ...
}

///|
/// Which model answered, and what the provider called the call.
///
/// The tail of every `lift_message`: all four providers name the model in
/// `model` and the call in `id`, at the top level of the reply. `fallback` is
/// what the dialect was configured with, for a provider that echoes neither.
#declaration_only
pub fn reply_identity(reply : Json, fallback~ : String) -> (String, String?) {
  ...
}
