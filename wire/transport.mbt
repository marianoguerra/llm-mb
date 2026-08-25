///|
/// A one-shot HTTP transport: POST the lowered body, hand
/// the whole response text to `on_chunk` as a single chunk. The dialect's
/// default `stream_finish` parses it, so this stays a byte pump that never
/// learns the dialect.
///
/// `spawn` is how a synchronous trait method does asynchronous work. The
/// trait is in continuations because the page's transport has to be, and
/// `@async.TaskGroup::spawn_bg` is itself a plain `fn`, so the frontend that
/// owns the group hands one of these its own way of starting a task. The
/// runtime is waiting on the answer either way.
pub(all) struct HttpTransport {
  url : String
  headers : Map[String, String]
  spawn : (async () -> Unit) -> Unit
}

///|
pub impl @llm.LlmTransport for HttpTransport with fn send(
  self,
  handle~,
  target~,
  body~,
  headers~,
  on_chunk~,
  on_done~,
  on_error~,
) {
  // The URL was resolved when this was built; the target is the core's name
  // for the call, and neither is this one's business beyond saying so.
  ignore(target)
  ignore(handle)
  // The merge lands in the wire's OWN map rather than being converted after
  // it: `@http` keys headers case-insensitively and `LlmTransport` cannot,
  // since a page implements the same trait and has no HTTP client to name a
  // type from. One walk, and the case rule that decides which of two spellings
  // wins is the socket's rather than a second one kept beside it.
  let all : Map[@http.CaseInsensitiveString, String] = Map([])
  for name, value in self.headers {
    all[@http.CaseInsensitiveString(name)] = value
  }
  for name, value in headers {
    all[@http.CaseInsensitiveString(name)] = value
  }
  (self.spawn)(() => {
    let (resp, data) = @http.post(self.url, body, headers=all) catch {
      err => {
        on_error(err.to_string())
        return
      }
    }
    ignore(resp.code) // error payloads are JSON too; the dialect lifts them
    on_chunk(data.text())
    on_done()
  })
}
