# JSON Form (`jsonForm`)

> **Audience:** Salesforce developers and administrators.
> **Scope:** the reusable `c-json-form` component, its demo host `c-json-form-demo`, and the project's local development setup.

`c-json-form` renders **any JSON** as a hierarchical form — one textbox for each field label and one textbox for each field value — and returns the modified JSON as the user edits it. It has no Apex or static-resource dependencies and can be dropped into any org on its own.

It is also the right-hand pane of the document previewer; see **[DOC_PREVIEWER.md](DOC_PREVIEWER.md)** for that use case.

---

## 1. `c-json-form`

`force-app/idp/main/default/lwc/jsonForm`

| API                     | Kind                                | Description                                                                                                                           |
| ----------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `json-data`             | `@api` property                     | The JSON to edit. Accepts an object/array **or** a JSON string. Intended for parent components.                                       |
| `json-input`            | `@api` property (String)            | String-only variant of `json-data`. This is the property exposed in App Builder and Flow, so the JSON source stays open/configurable. |
| `json-output`           | `@api` property (String, read-only) | The modified JSON string. Exposed as a Flow output attribute and kept in sync via `FlowAttributeChangeEvent`.                         |
| `edit-labels`           | `@api` property (Boolean)           | Whether object keys may be renamed. **Defaults to `false`**: field names render as plain text and only the values are editable.       |
| `onjsonchange`          | event                               | Fired on every edit. `event.detail.value` is the modified JSON object, `event.detail.jsonString` is the pretty-printed string.        |
| `getJson()`             | `@api` method                       | Returns the current (modified) JSON object on demand.                                                                                 |
| `getJsonString(indent)` | `@api` method                       | Returns the current JSON as a formatted string.                                                                                       |

### Behavior

- **Nested objects** render as indented sections with a "Group" badge; their fields render below them.
- **Arrays** render as sections with a "List" badge; items get fixed positional labels (`Item 1`, `Item 2`, …) since JSON array elements have no names — their values are still editable.
- **Labels are read-only unless `edit-labels` is set.** With it on, changing an object key's label renames the key in the JSON, preserving key order; renames to an empty or already-existing key are rejected and the textbox snaps back on blur. Array item labels are never editable either way, since they are positional rather than part of the JSON.
- **Edited fields are outlined in green** and tinted, so it is obvious what the user changed. The cue tracks the value, not the act of typing: restoring a field's original text clears it again.
- **Types are preserved**: a number stays a number (`"46"` → `46`), booleans stay booleans, strings (including ISO dates) stay strings. If the text no longer parses as the original type it is kept as a string.
- **Edit-only**: existing fields and array items can be edited, but not added or removed (deliberate scope decision).
- The incoming JSON is deep-cloned, so edits never mutate the object owned by the parent.

### Using it in a parent component

```html
<c-json-form
  json-data="{myJson}"
  edit-labels="{allowRenames}"
  onjsonchange="{handleJsonChange}"
></c-json-form>
```

```js
handleJsonChange(event) {
    this.modified = event.detail.value; // the modified JSON object
}
```

### Using it in a Screen Flow

The component is exposed to `lightning__FlowScreen` as **JSON Form**:

1. In Flow Builder, add a Screen element and drop **JSON Form** onto it.
2. Set **Source JSON** (`jsonInput`) to a text variable, formula, or literal containing the JSON.
   Switch on **Allow field names to be edited** (`editLabels`) if the user should be able to rename keys as well; it is off by default.
3. After the screen, read **Modified JSON** (`jsonOutput`) — it always contains the JSON string including the user's edits (it updates on every keystroke, so it is current no matter how the user leaves the screen).

### Using it on a Lightning page

**JSON Form** can also be dropped directly onto App, Home, and Record pages; the **Source JSON** property appears in the App Builder property panel.

---

## 2. `c-json-form-demo`

`force-app/idp/main/default/lwc/jsonFormDemo`

A demo host exposed to App, Home, Record pages and Tabs. Paste any JSON into the textarea, click **Load JSON**, edit the generated form, and watch the modified JSON output update live. Useful for smoke-testing a deployment or demonstrating the component without building a Flow.

To try it: deploy, then add **JSON Form Demo** to any Lightning App/Home/Record page via the Lightning App Builder.

---

## 3. Project setup

```sh
npm install                # dev tooling (Jest, ESLint, Prettier)
npm run test:unit          # run the LWC Jest tests (25 tests)
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

_Related docs: [README.md](README.md) (documentation index), [DOC_PREVIEWER.md](DOC_PREVIEWER.md) (document previewer that embeds this component), [LIQUIDITY_CALCULATOR.md](LIQUIDITY_CALCULATOR.md) (unrelated LQC component)._
