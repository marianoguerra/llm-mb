// Where the bytes go. Two implementations ship: this one, which hands the
// call to a relay holding the credential, and `llm/wire`'s, which holds one
// itself. A page can only have the first; a server can have either.

///|
/// Default: a transport with no way to stop a call in flight says so by
/// doing nothing, rather than by not being askable.
impl LlmTransport with fn abort(_self : Self, handle~ : String) -> Unit {
  ignore(handle)
}

///|
pub fn RelayTransport::make(
  post~ : (String, String, String, (String) -> Unit, (String) -> Unit) -> Unit,
  stop? : (String) -> Unit = _ => (),
) -> RelayTransport {
  { post, stop, }
}

///|
pub impl LlmTransport for RelayTransport with fn send(
  self,
  handle~,
  target~,
  body~,
  headers~,
  on_chunk~,
  on_done~,
  on_error~,
) {
  // A relay is reached through whatever door its holder already has open —
  // a page's `fetch`, a worker's queue — and the headers of THAT call are
  // its business, not this one's. What a per-call header here would mean is
  // "add this to the upstream request", which is a thing only the side with
  // the credential can honour.
  ignore(headers)
  (self.post)(
    handle,
    target,
    body.stringify(),
    reply => {
      on_chunk(reply)
      on_done()
    },
    on_error,
  )
}

///|
pub impl LlmTransport for RelayTransport with fn abort(self, handle~) {
  (self.stop)(handle)
}
