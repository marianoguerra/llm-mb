// The one table. What used to be three — a `match provider` for the page, a
// closure table with the credentials for the server, and a set of capability
// rows for one of the four — held together by tests that walked one looking
// for the other.

///|
pub fn Registry::of(
  apis : Array[ApiSpec],
  providers : Array[ProviderSpec],
) -> Registry {
  let by_id : Map[String, ApiSpec] = Map([])
  for api in apis {
    by_id[api.id] = api
  }
  { apis: by_id, providers, }
}

///|
pub fn Registry::with_provider(
  self : Registry,
  spec : ProviderSpec,
) -> Registry {
  let providers = self.providers.copy()
  match providers.search_by(p => p.id == spec.id) {
    Some(at) => providers[at] = spec
    None => providers.push(spec)
  }
  { apis: self.apis, providers, }
}

///|
pub fn Registry::with_model(
  self : Registry,
  provider~ : String,
  info : ModelInfo,
) -> Registry? {
  guard self.providers.search_by(p => p.id == provider) is Some(at) else {
    return None
  }
  let spec = self.providers[at]
  let models = spec.models.copy()
  match models.search_by(m => m.id == info.id) {
    Some(i) => models[i] = info
    None => models.push(info)
  }
  let providers = self.providers.copy()
  providers[at] = { ..spec, models, }
  Some({ apis: self.apis, providers, })
}

///|
pub fn Registry::with_api(self : Registry, spec : ApiSpec) -> Registry {
  let apis = self.apis.copy()
  apis[spec.id] = spec
  { apis, providers: self.providers, }
}

///|
pub fn Registry::api(self : Registry, id : String) -> ApiSpec? {
  self.apis.get(id)
}

///|
pub fn Registry::provider(self : Registry, id : String) -> ProviderSpec? {
  guard self.providers.search_by(p => p.id == id) is Some(i) else {
    return None
  }
  Some(self.providers[i])
}

///|
pub fn split_label(label : String) -> (String, String) {
  guard label.find(":") is Some(i) else { return (label, "") }
  (label[0:i].to_owned(), label[i + 1:].to_owned())
}

///|
/// The row `provider` has for `model`, if it lists one.
fn ProviderSpec::listed(self : ProviderSpec, model : String) -> ModelInfo? {
  guard self.models.search_by(m => m.id == model) is Some(i) else {
    return None
  }
  Some(self.models[i])
}

///|
/// Which API answers for this model of this provider: the model's own
/// override if it has one, else the provider's.
fn ProviderSpec::api_of(self : ProviderSpec, info : ModelInfo) -> String {
  info.api.unwrap_or(self.api)
}

///|
pub fn Registry::model_info(
  self : Registry,
  provider~ : String,
  model~ : String,
) -> ModelInfo? {
  guard self.provider(provider) is Some(spec) else { return None }
  let wanted = if model == "" { spec.default_model } else { model }
  if spec.listed(wanted) is Some(info) {
    return Some(info)
  }
  // Not listed is not unknown: the page may have been offered a model by a
  // proxy whose table is newer than this one, and refusing to lower for it
  // would strand a selector the user is already looking at. `endpoint` is
  // where an unlisted model IS refused, because that is where the name
  // reaches a URL.
  match self.api(spec.api) {
    Some(api) => Some((api.caps)(wanted))
    None => Some(ModelInfo::permissive(wanted))
  }
}

///|
pub fn Registry::labels(self : Registry) -> Array[String] {
  let out : Array[String] = []
  for spec in self.providers {
    for info in spec.models {
      out.push("\{spec.id}:\{info.id}")
    }
  }
  out
}

///|
pub fn Registry::dialect_of(self : Registry, label : String) -> &Dialect? {
  let (provider, model) = split_label(label)
  guard self.provider(provider) is Some(spec) else { return None }
  guard self.model_info(provider~, model~) is Some(info) else { return None }
  guard self.api(spec.api_of(info)) is Some(api) else { return None }
  Some((api.make)(info))
}

///|
pub fn Registry::provider_for_api(
  self : Registry,
  api : String,
) -> ProviderSpec? {
  guard self.providers.search_by(p => p.api == api) is Some(i) else {
    return None
  }
  Some(self.providers[i])
}

///|
pub fn Registry::endpoint(
  self : Registry,
  provider~ : String,
  model~ : String,
  key~ : String,
) -> Result[(String, Map[String, String]), String] {
  guard self.provider(provider) is Some(spec) else {
    return Err("no provider called \{provider}")
  }
  let wanted = if model == "" { spec.default_model } else { model }
  guard spec.listed(wanted) is Some(_) else {
    return Err(
      "\{spec.id} here does not serve \{wanted} — the model list is what it does",
    )
  }
  let url = spec.endpoint.replace(old="{model}", new=wanted)
  let headers = spec.headers.copy()
  let url = match spec.auth {
    BearerHeader => {
      headers["authorization"] = "Bearer \{key}"
      url
    }
    KeyHeader(name) => {
      headers[name] = key
      url
    }
    KeyQuery(name) => {
      let sep = if url.contains("?") { "&" } else { "?" }
      "\{url}\{sep}\{name}=\{key}"
    }
    NoAuth => url
  }
  Ok((url, headers))
}
