# Native editable-text contract

`editable-text-contract.patch` applies after the three patches in PATCHES.md.
It repairs native Linux observations and replacement without changing Atreyu,
using CDP, or changing the Hyprland plugin.

## Observation

`get_window_state.structuredContent.elements` keeps the existing window-bound
element tokens and adds the following native evidence. Unknown optional fields
are omitted; they are never fabricated from the role or label.

| Field | Contract |
| --- | --- |
| `editable` | Boolean from native Editable/ReadOnly state, or EditableText evidence if state is unavailable. Omitted if unknown. Does not promise that native replacement is available. |
| `editable_source` | Native evidence used for editability. |
| `value` | Actual string, including `""`. Missing means unreadable/unavailable, not empty. Numeric AT-SPI Value remains a string. |
| `value_complete` | True only when the complete value was read. |
| `value_status` | `complete`, `truncated`, `incomplete`, `changed_during_read`, `protected`, `protection_unknown`, `stale`, `platform_truncated`, `deadline`, `read_failure`, `unavailable`, or `not_applicable`. |
| `value_source` | `atspi.Text.GetText` or `atspi.Value.CurrentValue` when applicable. |
| `protected` | True when native role/attributes establish a protected field; its value is omitted. Unknown protection yields no value and `protection_unknown`. |
| `accessible_name` | Native computed name, when present; separate from current text. |
| `name_source`, `name_complete` | Native name provenance and read completeness. |
| `label`, `label_source` | For fields, supplied only with explicit native attribute/related-element name provenance. Content-derived, placeholder-derived, and unknown names remain `accessible_name`, not an asserted field label. |
| `placeholder`, `placeholder_source` | Native placeholder attribute, when available. |
| `description`, `description_source`, `description_complete` | Separate native description and its provenance/read status. |
| `input_type`, `input_type_source` | Only a native `text-input-type` or `input-type` attribute. No search-purpose inference from role, name, placeholder, or children. |
| `input_type_status` | `known`, `unavailable`, `read_failure`, or `not_applicable`. |
| `attributes_complete` | Whether the native attribute query succeeded. |

Example from the disposable Chromium fixture (identity/geometry fields omitted):

```json
{
  "role": "entry",
  "accessible_name": "Fixture search",
  "name_source": "atspi.name-from:related-element",
  "name_complete": true,
  "label": "Fixture search",
  "label_source": "atspi.name-from:related-element",
  "editable": true,
  "editable_source": "atspi.State.Editable/ReadOnly",
  "value": "",
  "value_complete": true,
  "value_status": "complete",
  "value_source": "atspi.Text.GetText",
  "protected": false,
  "placeholder": "Find fixture items",
  "placeholder_source": "atspi.attribute:placeholder",
  "description": "Editable query description",
  "description_source": "atspi.description-from:aria-description",
  "description_complete": true,
  "input_type": "search",
  "input_type_source": "atspi.attribute:text-input-type",
  "input_type_status": "known",
  "attributes_complete": true
}
```

Text reads compare character counts and two reads, then recheck native
protection/state/attributes before publishing. The cap is 65,536 Unicode scalar
characters; a returned prefix is explicitly `truncated` and incomplete.
Changing reads are omitted. Markdown and native page-query output preserve
the completeness and name/value distinction too.

`verify_state` consumes these observations. Incomplete or protected values can
prove neither equality nor inequality. Existing web-content trust restrictions
remain: GTK/native widget predicates can verify values, while web-content
predicates still return unknown under that policy.

## Replacement

`set_value` uses only native `EditableText.SetTextContents` for text replacement
or `Value.SetCurrentValue` for numeric controls. The former is the native
[whole-content replacement operation](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/method.EditableText.set_text_contents.html).
The caret-based InsertText fallback is removed. There is no automatic focus,
clear-and-insert sequence, transport fallback or mutation retry.

The existing public action contract reports `effect: "confirmed"` only after
complete fresh native readback equals the requested value and retained-target
identity is revalidated. Unsupported/protected/readonly targets return an
error and `effect: "refused"`. Failures after a mutation attempt return an error
with `outcome_uncertain:` and `effect: "unverifiable"`, with unknown delivery.
Neither response echoes requested text. Cancellation before delivery refuses;
cancellation after an attempt is uncertain. The native worker retains session
admission until it exits.

Chromium in the tested environment exposes readable Text but no EditableText,
even after native activation. Therefore this patch fixes Chromium observation
but **does not enable native `set_value` replacement there**. It explicitly
refuses that unsupported method. GTK's native replacement route was exercised
successfully. Clients must distinguish `editable` from replacement support.

## Validation boundaries

Owned Chromium and GTK fixtures use persistent MCP in Atreyu's sanitized
environment. GTK independently journals widget values; Chromium's loopback
fixture journals its controls without CDP. Tested sequences include empty,
`Deep House`, replacement with `Ambient Drift`, Unicode, and clearing. GTK
`verify_state` confirms each value. A four-character widget limit transforms
`Deep House` into `Deep`: action confirmation is refused and fresh observation
reports the actual value. Protected/readonly targets and stale/wrong-window
tokens refuse. Search/Play activation and numeric slider value 37 still work.

The current personal Suno window refused exact-window identity for both the
installed baseline and the candidate during read-only checks. This prevents
Suno-specific acceptance in this run; no personal input was sent. It does not
invalidate the earlier traversal evidence or establish a new regression.
Cancellation-before-dispatch is unit tested; interrupted D-Bus acknowledgement
is not fault-injected live. Raw browser captures remain private.

Final locally built CLI SHA256:
`804f088a644083313e219d186c7fc2dcc5ca28b10eea9922c5bbce038ee2fda8`.
The package remains a local unsigned x86_64 experiment; installing it requires
coordinating the Atreyu MCP reconnection.
