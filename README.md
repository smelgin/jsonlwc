# JsonLwc

Salesforce DX project containing a Lightning Web Component that renders **any JSON** as a hierarchical form — one textbox for each field label and one textbox for each field value — and returns the modified JSON as the user edits it.

The project also contains the **Liquidity Calculator (LQC)** — a configuration-driven, multi-tab editable grid for Case pages. It is documented separately in **[LIQUIDITY_CALCULATOR.md](LIQUIDITY_CALCULATOR.md)** (configuration reference, `ILqcPrefill` contract, and org-to-org deployment steps).

## Components

### `c-json-form` (force-app/main/default/lwc/jsonForm)

The reusable editor component.

| API | Kind | Description |
| --- | --- | --- |
| `json-data` | `@api` property | The JSON to edit. Accepts an object/array **or** a JSON string. Intended for parent components. |
| `json-input` | `@api` property (String) | String-only variant of `json-data`. This is the property exposed in App Builder and Flow, so the JSON source stays open/configurable. |
| `json-output` | `@api` property (String, read-only) | The modified JSON string. Exposed as a Flow output attribute and kept in sync via `FlowAttributeChangeEvent`. |
| `onjsonchange` | event | Fired on every edit. `event.detail.value` is the modified JSON object, `event.detail.jsonString` is the pretty-printed string. |
| `getJson()` | `@api` method | Returns the current (modified) JSON object on demand. |
| `getJsonString(indent)` | `@api` method | Returns the current JSON as a formatted string. |

Behavior:

- **Nested objects** render as indented sections with a "Group" badge; their fields render below them.
- **Arrays** render as sections with a "List" badge; items get fixed positional labels (`Item 1`, `Item 2`, …) since JSON array elements have no names — their values are still editable.
- **Labels are editable** for object keys: changing a label renames the key in the JSON, preserving key order. Renames to an empty or already-existing key are rejected and the textbox snaps back on blur.
- **Types are preserved**: a number stays a number (`"46"` → `46`), booleans stay booleans, strings (including ISO dates) stay strings. If the text no longer parses as the original type it is kept as a string.

Example usage in a parent component:

```html
<c-json-form json-data={myJson} onjsonchange={handleJsonChange}></c-json-form>
```

```js
handleJsonChange(event) {
    this.modified = event.detail.value; // the modified JSON object
}
```

#### Using it in a Screen Flow

The component is exposed to `lightning__FlowScreen` as **JSON Form**:

1. In Flow Builder, add a Screen element and drop **JSON Form** onto it.
2. Set **Source JSON** (`jsonInput`) to a text variable, formula, or literal containing the JSON.
3. After the screen, read **Modified JSON** (`jsonOutput`) — it always contains the JSON string including the user's edits (it updates on every keystroke, so it is current no matter how the user leaves the screen).

#### Using it on a Lightning page

**JSON Form** can also be dropped directly onto App, Home, and Record pages; the **Source JSON** property appears in the App Builder property panel. Only edits to existing fields are supported — fields and array items cannot be added or removed.

### `c-file-json-review` (force-app/main/default/lwc/fileJsonReview)

Split-screen review component: a Salesforce file preview on the left, the `c-json-form` editor on the right, separated by a divider you can drag with the mouse (or move with the arrow keys when focused).

| API | Kind | Description |
| --- | --- | --- |
| `content-document-id` | `@api` property (String) | Id of the file (ContentDocument) to preview. PDF renders in an inline viewer; JPG/PNG/GIF render as images; other types show a friendly message. |
| `json-input` | `@api` property (String) | The JSON string to edit in the right pane. |
| `json-output` | `@api` property (String, read-only) | The JSON string including the user's edits. Exposed as a Flow output attribute. |
| `height` | `@api` property (String) | CSS height of the component (default `600px`). |
| `submit-label` | `@api` property (String) | Label of the Save button (default `Save`). |
| `onjsonchange` | event | Re-emitted from the child form on every edit. |
| `onjsonsubmit` | event | Fired when the Save button is clicked. `event.detail.value` is the modified JSON object, `event.detail.jsonString` the string — use it to persist the result. |

A **Save** button in the right pane returns the current JSON so a host can store it back to a field. A parent component listens for `jsonsubmit`; in a Screen Flow / OmniScript the click also refreshes the `jsonOutput` attribute (which already updates live on every edit). Example parent handler:

```js
handleJsonSubmit(event) {
    // event.detail.jsonString → save to a field via your own Apex/updateRecord
    this.payload = event.detail.jsonString;
}
```

File metadata (title, extension, size, latest version id) is resolved by the `FilePreviewController` Apex class (`WITH USER_MODE`, so the running user's file access is enforced).

**Images** load straight from the standard `/sfc/servlet.shepherd` endpoint in an `<img>` (an image tag follows the servlet's cross-origin redirect natively).

**PDFs** are rendered by a bundled **PDF.js** viewer (the `pdfjs` static resource) running in an iframe, so rendering is consistent across desktop, mobile, and embedded WebViews rather than depending on the browser's built-in PDF plugin. The flow:

1. `FilePreviewController.getFileBase64` returns the file bytes as base64 (checked against a size cap first, so an oversized file never loads into Apex heap).
2. The LWC hands those bytes to the viewer iframe via `postMessage` — this keeps everything same-origin and avoids the cross-origin redirect that blocks a direct `fetch()` of the Files servlet.
3. The viewer (`staticresources/pdfjs/viewer.html`) imports `pdf.mjs` as a module and renders each page to a canvas.

If PDF.js can't render — file larger than `FilePreviewController.MAX_PREVIEW_BYTES` (3 MB), an Apex error, or the viewer failing to load within 10 s — the component automatically falls back to the browser's native preview. CJK documents need the PDF.js `cmaps` (not bundled to save space); add them to the static resource if required.

### Updating the bundled PDF.js

Download `pdfjs-<version>-legacy-dist.zip` from [mozilla/pdf.js releases](https://github.com/mozilla/pdf.js/releases). Replace the `wasm/`, `standard_fonts/`, `iccs/` folders and the build files in `staticresources/pdfjs/`, keeping the custom `viewer.html`. Keep the total under the 5 MB static-resource limit (exclude `*.map` files). PDF.js parses untrusted files, so update periodically for security fixes.

> **Critical:** rename `pdf.mjs` → `pdf.js` and `pdf.worker.mjs` → `pdf.worker.js`, and update the internal `./pdf.worker` reference inside `pdf.js` to `.js`. Salesforce serves `.mjs` files as `application/octet-stream`, and browsers refuse to execute a module script with that MIME type (`Failed to load module script … Strict MIME type checking is enforced`). `viewer.html` already imports the `.js` names.

#### Screen Flow

Drop **File and JSON Review** on a Screen, set **Content Document Id** and **Source JSON** (text variables), and read **Modified JSON** after the screen.

#### OmniStudio

- **OmniScript**: add a *Custom Lightning Web Component* element with `fileJsonReview` as the component name, and map `contentDocumentId` and `jsonInput` in Custom LWC Properties (e.g. `%ContentDocumentId%`, or `=JSON(...)` of a data node). To push `jsonOutput` back into the OmniScript data JSON, create a thin wrapper component in an org with OmniStudio installed that extends `OmniscriptBaseMixin(FileJsonReview)` and calls `this.omniUpdateDataJson(...)` from the `jsonchange` handler — the mixin isn't imported here so this project deploys to any org.
- **FlexCard**: embed via the *Custom LWC* element and pass `contentDocumentId` / `jsonInput` as attributes bound to card data (e.g. `{record.ContentDocumentId}`).

### `c-json-form-demo` (force-app/main/default/lwc/jsonFormDemo)

A demo host exposed to App, Home, Record pages and Tabs. Paste any JSON into the textarea, click **Load JSON**, edit the generated form, and watch the modified JSON output update live.

## Getting started

```sh
npm install                # dev tooling (Jest, ESLint, Prettier)
npm run test:unit          # run the LWC Jest tests (25 tests)
sf org login web -a myorg  # authorize an org
sf project deploy start -o myorg   # deploy
```

Then add the **JSON Form Demo** component to any Lightning App/Home/Record page via the Lightning App Builder.

## VS Code

The `.vscode` folder recommends the Salesforce Extension Pack; open the folder in VS Code and install the recommended extensions when prompted.
