// The one thing about this executable that can be checked without spending
// money: that the table naming the cheap models names models that exist.

///|
/// Every id `smoke_model` returns has to be one the catalog lists, because
/// `model_for` answers an unlisted id with the provider's DEFAULT rather than
/// an error — right for an operator's sixth vendor, and silent for a stale
/// entry here. Silent is the problem: the run still passes, still exercises
/// the provider, and costs whatever the default costs. Trimming the catalog
/// to two models per size group broke two of these five, and a full run moved
/// onto gpt-5.6-sol without saying so.
test "smoke: the cheap models are models the catalog still lists" {
  let registry = @catalog.default_registry()
  for spec in registry.providers {
    guard smoke_model(spec.id) is Some(want) else { continue }
    assert_true(
      spec.models.search_by(m => m.id == want) is Some(_),
      // Which provider, so the failure names the row to edit.
      msg="smoke_model(\{spec.id}) wants \{want}, which \{spec.id} no longer lists — model_for would fall back to \{spec.default_model} and the run would cost that instead",
    )
    // And the fallback is not silently what we asked for anyway.
    assert_eq(model_for(spec), want)
  }
}
