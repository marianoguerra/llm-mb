// Explicit method promotions for the derived trait impls on the IR types.
// Implicit promotion is deprecated by the compiler; these keep `x.to_json()`
// and friends compiling for consumers, with a deprecation pointing at the
// trait (`Json(x)`, `==`, `Debug`).

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend UserBlock with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend UserBlock with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend AssistantBlock with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend AssistantBlock with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend StopReason with Eq::{not_equal, equal}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend StopReason with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend StopReason with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Usage with Eq::{not_equal, equal}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Usage with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Usage with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ContextMessage with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ContextMessage with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ToolDecl with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ToolDecl with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ThinkingLevel with Eq::{not_equal, equal}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ThinkingLevel with Compare::{op_lt, op_le, op_ge, op_gt}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ThinkingLevel with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ThinkingLevel with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ReasoningContext with Eq::{not_equal, equal}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ReasoningContext with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ReasoningContext with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend CacheRetention with Eq::{not_equal, equal}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend CacheRetention with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend CacheRetention with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend LlmParams with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend LlmParams with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend LlmContext with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend LlmContext with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Modality with Eq::{not_equal, equal}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Modality with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Modality with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Cost with Eq::{not_equal, equal}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Cost with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Cost with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ModelInfo with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ModelInfo with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend DialectError with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend DialectError with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend StreamState with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend AuthStyle with Eq::{not_equal, equal}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend AuthStyle with Debug::{to_repr}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend AuthStyle with ToJson::{to_json}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend ProviderSpec with Debug::{to_repr}
