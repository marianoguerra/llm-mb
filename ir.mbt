// Bodies for the IR's own constructors and parsers. Anything that reads a
// message is a dialect's job; this is only what the IR owes itself.

///|
pub fn Usage::make(
  input~ : Int,
  output~ : Int,
  cache_read? : Int = 0,
  cache_write? : Int = 0,
) -> Usage {
  { input, output, cache_read, cache_write }
}

///|
pub fn Usage::from_json(value : Json) -> Usage? {
  guard value
    is { "input": Number(input, ..), "output": Number(output, ..), .. } else {
    return None
  }
  let cache_read = match value {
    { "cache_read": Number(n, ..), .. } => n.to_int()
    _ => 0
  }
  let cache_write = match value {
    { "cache_write": Number(n, ..), .. } => n.to_int()
    _ => 0
  }
  Some(
    Usage::make(
      input=input.to_int(),
      output=output.to_int(),
      cache_read~,
      cache_write~,
    ),
  )
}
