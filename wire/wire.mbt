// Reading credentials out of an environment, and posting bytes with them.

///|
/// The credential for one provider, out of the variable its row names. The
/// only place in this module that reads an environment.
///
/// A provider whose `key_env` is empty needs none — a local endpoint — and
/// answers with the empty string rather than None, because "no key" and "key
/// not set" are different situations and only the second is a reason to skip
/// it.
pub fn key_of(spec : @llm.ProviderSpec) -> String? {
  if spec.key_env == "" {
    return Some("")
  }
  @env.get_env_var(spec.key_env)
}

///|
/// Every provider in `registry` whose credential is present, with it.
/// In registry order, which is the order a selector should offer them in.
pub fn configured(
  registry : @llm.Registry,
) -> Array[(@llm.ProviderSpec, String)] {
  let out : Array[(@llm.ProviderSpec, String)] = []
  for spec in registry.providers {
    if key_of(spec) is Some(key) {
      out.push((spec, key))
    }
  }
  out
}

///|
/// The model this environment wants from `spec`: the operator's override for
/// THIS provider, else the provider's own default.
///
/// A global "use this model" variable is deliberately not read here. The
/// provider was named by whoever is asking, and applying one provider's model
/// to another is exactly how a Gemini call went out asking for
/// `models/gpt-5.4-mini`. `from_env` reads one, because there it is the model
/// of the provider that same environment picked.
pub fn model_of(spec : @llm.ProviderSpec) -> String {
  if spec.model_env == "" {
    return spec.default_model
  }
  @env.get_env_var(spec.model_env).unwrap_or(spec.default_model)
}

///|
/// The provider and model this environment selects, and its credential.
///
/// `provider_env`, `model_env` and `priority` are arguments rather than
/// constants because the variable naming a provider belongs to the
/// application asking, not to this module — `MYAPP_PROVIDER` is one spelling
/// and this is meant to outlive it. Note the asymmetry with the per-provider
/// `LLM_*_MODEL` names a `ProviderSpec` DOES carry: those are this module's,
/// these two are the caller's. `priority` is the order to try when nothing
/// named a provider: the first one whose key is set wins.
///
/// A `provider_env` naming something this build does not know is ignored
/// rather than refused — falling back to a configured provider gets a person
/// working, and a typo in a variable should not look like a missing key.
pub fn from_env(
  registry : @llm.Registry,
  priority~ : Array[String],
  provider_env~ : String,
  model_env~ : String,
) -> (@llm.ProviderSpec, String, String)? {
  let named = if provider_env == "" {
    None
  } else {
    @env.get_env_var(provider_env)
  }
  let chosen = match named {
    Some(name) if registry.provider(name) is Some(spec) &&
      key_of(spec) is Some(_) => Some(spec)
    _ => {
      let mut found : @llm.ProviderSpec? = None
      for candidate in priority {
        if registry.provider(candidate) is Some(spec) && key_of(spec) is Some(_) {
          found = Some(spec)
          break
        }
      }
      found
    }
  }
  guard chosen is Some(spec) else { return None }
  guard key_of(spec) is Some(key) else { return None }
  let model = if model_env == "" {
    model_of(spec)
  } else {
    @env.get_env_var(model_env).unwrap_or(model_of(spec))
  }
  Some((spec, model, key))
}

///|
/// Where a call to this provider's model goes, with the credential read from
/// the environment. `Err` is what to tell whoever asked.
pub fn endpoint_for(
  registry : @llm.Registry,
  provider~ : String,
  model~ : String,
) -> Result[(String, Map[String, String]), String] {
  guard registry.provider(provider) is Some(spec) else {
    return Err("no provider called \{provider}")
  }
  guard key_of(spec) is Some(key) else {
    return Err("\{spec.name} has no credential (\{spec.key_env} is not set)")
  }
  registry.endpoint(provider~, model~, key~)
}
