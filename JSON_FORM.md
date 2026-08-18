# JSON Form (`jsonForm`)

> **Audience:** Salesforce developers and administrators.
> **Scope:** the reusable `c-json-form` component, its demo host `c-json-form-demo`, and the project's local development setup.

`c-json-form` renders **any JSON** as a hierarchical form — one textbox for each field label and one textbox for each field value — and returns the modified JSON as the user edits it. It has no Apex or static-resource dependencies and can be dropped into any org on its own.

It is also the right-hand pane of the document previewer; see **[DOC_PREVIEWER.md](DOC_PREVIEWER.md)** for that use case.

---

## 1. `c-json-form`

`force-app/idp/main/default/lwc/jsonForm`

| API                     | Kind                                | Description                                                                                                                                                            |
| ----------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `json-data`             | `@api` property                     | The JSON to edit. Accepts an object/array **or** a JSON string. Intended for parent components.                                                                        |
| `json-input`            | `@api` property (String)            | String-only variant of `json-data`. This is the property exposed in App Builder and Flow, so the JSON source stays open/configurable.                                  |
| `json-output`           | `@api` property (String, read-only) | The modified JSON string. Exposed as a Flow output attribute and kept in sync via `FlowAttributeChangeEvent`.                                                          |
| `edit-labels`           | `@api` property (Boolean)           | Whether object keys may be renamed. **Defaults to `false`**: field names render as plain text and only the values are editable.                                        |
| `edit-structure`        | `@api` property (Boolean)           | Whether fields, list items and groups may be added and deleted. **Defaults to `false`**.                                                                               |
| `collapsible`           | `@api` property (Boolean)           | Whether groups and lists can be collapsed. **Defaults to `false`**.                                                                                                    |
| `searchable`            | `@api` property (Boolean)           | Whether a search box filters the form. **Defaults to `false`**.                                                                                                        |
| `show-confidence`       | `@api` property (Boolean)           | Whether `{value, confidence}` envelopes are unwrapped and badged. **Defaults to `false`**.                                                                             |
| `confidence-threshold`  | `@api` property (Number)            | Confidence below which the badge turns red. Fraction (`0.8`) or percentage (`80`). Defaults to `0.8`.                                                                  |
| `validate-types`        | `@api` property (Boolean)           | Whether values that no longer parse as their loaded type are flagged. **Defaults to `false`**.                                                                         |
| `is-valid`              | `@api` property (Boolean, get-only) | `false` when `validate-types` is on and some field is invalid. Always `true` when validation is off.                                                                   |
| `onjsonchange`          | event                               | Fired on every edit. `event.detail.value` is the modified JSON object, `event.detail.jsonString` the pretty-printed string, `event.detail.valid` the current validity. |
| `getJson()`             | `@api` method                       | Returns the current (modified) JSON object on demand.                                                                                                                  |
| `getJsonString(indent)` | `@api` method                       | Returns the current JSON as a formatted string.                                                                                                                        |

### Behavior

- **Nested objects** render as indented sections with a "Group" badge; their fields render below them.
- **Arrays** render as sections with a "List" badge; items get fixed positional labels (`Item 1`, `Item 2`, …) since JSON array elements have no names — their values are still editable.
- **Labels are read-only unless `edit-labels` is set.** With it on, changing an object key's label renames the key in the JSON, preserving key order; renames to an empty or already-existing key are rejected and the textbox snaps back on blur. Array item labels are never editable either way, since they are positional rather than part of the JSON.
- **Edited fields are outlined in green** and tinted, so it is obvious what the user changed. The cue tracks the value, not the act of typing: restoring a field's original text clears it again.
- **Types are preserved**: a number stays a number (`"46"` → `46`), booleans stay booleans, strings (including ISO dates) stay strings. If the text no longer parses as the original type it is kept as a string.
- The incoming JSON is deep-cloned, so edits never mutate the object owned by the parent.

**Everything past editing values is opt-in**, so a host that sets none of the flags below behaves exactly as the component always has.

#### `edit-structure` — adding and deleting

Adds an **Add field** button to the toolbar and to every group and list, and a delete button to every row. Adding asks for a name (objects only — list items are positional) and a type: Text, Number, True/false, Empty, Group or List. Names that are blank or already taken by a sibling are rejected with a message. A new field is outlined in green from birth, since nothing about it came from the document. Deleting a leaf happens immediately; deleting a group or list that has contents asks first. Deleting a list item renumbers the survivors.

#### `collapsible` — collapse and expand

Puts a chevron on every group and list, plus **Expand all** / **Collapse all** in the toolbar. Purely a view state: collapsing never changes the JSON.

#### `searchable` — filtering

Adds a search box that matches field names and values, case-insensitively. Matches are shown **in context** — the parent groups of a match stay visible, and matching a group's name shows its whole subtree. A search temporarily overrides collapse, so a match can never stay hidden inside a group the user had closed. When nothing matches, the form says so rather than looking empty.

#### `show-confidence` — extraction confidence

An IDP service can wrap any node as `{"value": …, "confidence": 0.93}`. With this off, that is ordinary JSON and renders as a two-field group — which is the right thing to show a host that knows nothing about confidence. With it on, the envelope is unwrapped so the field shows its actual value with the confidence as a badge, red below `confidence-threshold`. **The envelope is restored in the output JSON either way**, edits included. The envelope shape is deliberately identical to `IdpJsonReader.isEnvelope` — exactly the two keys `value` and `confidence` — so a legitimate business field named `value` is never swallowed.

#### `validate-types` — type checking

Checks each edit against the type the field arrived with and outlines failures in red with a message, instead of silently keeping the text as a string. Only numbers and booleans can fail: a field that loaded as text accepts any text, and one that loaded empty accepts anything — that is the whole of "the type it arrived with", since no schema is involved. Read `is-valid`, or `event.detail.valid` on `jsonchange`, to gate a Save button.

### Using it in a parent component

```html
<c-json-form
    json-data="{myJson}"
    edit-labels="{allowRenames}"
    edit-structure
    collapsible
    searchable
    show-confidence
    validate-types
    onjsonchange="{handleJsonChange}"
></c-json-form>
```

```js
handleJsonChange(event) {
    this.modified = event.detail.value; // the modified JSON object
    this.canSave = event.detail.valid;  // false while a field is the wrong type
}
```

### Using it in a Screen Flow

The component is exposed to `lightning__FlowScreen` as **JSON Form**:

1. In Flow Builder, add a Screen element and drop **JSON Form** onto it.
2. Set **Source JSON** (`jsonInput`) to a text variable, formula, or literal containing the JSON.
   Every other capability is a separate checkbox, all off by default: **Allow field names to be edited** (`editLabels`), **Allow fields to be added and deleted** (`editStructure`), **Allow groups to be collapsed** (`collapsible`), **Show a search box** (`searchable`), **Show extraction confidence** (`showConfidence`, with **Low confidence below**) and **Flag values of the wrong type** (`validateTypes`). Switch on only what that screen needs.
3. After the screen, read **Modified JSON** (`jsonOutput`) — it always contains the JSON string including the user's edits (it updates on every keystroke, so it is current no matter how the user leaves the screen).

### Using it on a Lightning page

**JSON Form** can also be dropped directly onto App, Home, and Record pages; the **Source JSON** property and the same set of feature checkboxes appear in the App Builder property panel.

---

## 2. `c-json-form-demo`

`force-app/idp/main/default/lwc/jsonFormDemo`

A demo host exposed to App, Home, Record pages and Tabs. Paste any JSON into the textarea, click **Load JSON**, edit the generated form, and watch the modified JSON output update live. Useful for smoke-testing a deployment or demonstrating the component without building a Flow.

To try it: deploy, then add **JSON Form Demo** to any Lightning App/Home/Record page via the Lightning App Builder.

---

## 3. Project setup

```sh
npm install                # dev tooling (Jest, ESLint, Prettier)
npm run test:unit          # run the LWC Jest tests (76 tests)
sf org login web -a myorg  # authorize an org
sf project deploy start -o myorg   # deploy
```

Validate without changing an org (useful before a production deploy):

```sh
sf project deploy start -o myorg --dry-run --test-level RunLocalTests
```

### VS Code

The `.vscode` folder recommends the Salesforce Extension Pack; open the folder in VS Code and install the recommended extensions when prompted.

### Linting note

`eslint.config.js` ignores `**/staticresources/**` so the bundled third-party PDF.js library is not linted or reformatted. Keep that ignore in place.

---

_Related docs: [README.md](README.md) (documentation index), [DOC_PREVIEWER.md](DOC_PREVIEWER.md) (document previewer that embeds this component)._
