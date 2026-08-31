# Configuring a document type

This is the manual for the JSON that tells the IDP engine what to pull out of
a document and where to put it. If you are adding a field to an existing
document type, changing which record a value lands on, or onboarding a new
document type entirely, this is the file you need.

You do not need to be a developer to use it. You do need to be careful, because
this JSON is the thing the engine obeys.

**Contents**

- [Where the configuration lives](#where-the-configuration-lives)
- [Adding a new document type](#adding-a-new-document-type)
- [The shape of it](#the-shape-of-it)
- [Sections — regions of a document](#sections--regions-of-a-document)
- [Rules — one field each](#rules--one-field-each)
- [Value maps — translating wording](#value-maps--translating-wording)
- [Common jobs](#common-jobs)
- [When something is wrong](#when-something-is-wrong)
- [Rules of thumb](#rules-of-thumb)
- [Recipes](#recipes)

## Where the configuration lives

Each document type is one **IDP Mapping Set** record, and its whole
configuration sits in one field on that record, `Definition__c`, as JSON.

There are two ways in:

- **The IDP Configuration page** — App Launcher → **IDP Configuration**. Pick a
  document type on the left, edit its sections and rules as a form on the
  right, press **Check** to validate and **Save** to publish. This is the
  recommended route, and the one this manual assumes.
- **Setup → Custom Metadata Types → IDP Mapping Set → Manage Records**, editing
  the Definition field directly. Same field, no safety net.

Two things to expect when you save:

**Saving takes a few seconds, not instantly.** Configuration is metadata, not
data, so publishing it is a deployment. The Configurator waits for it and tells
you when it has landed. If you edit in Setup, the change is live once the page
returns.

**You need permission to save.** The **IDP Configurator** permission set gets
you the page. Saving additionally requires _Customize Application_ or _Modify
Metadata Through Metadata API_, which that permission set deliberately does not
grant — they are org-wide permissions and worth a separate decision. If Save
reports a permission problem, that is what it means; ask an administrator
rather than retrying.

**You do not have to write JSON.** The **Rules** tab is a form: object and
field pickers, dropdowns for the policies, toggles for active and required,
and buttons to add or delete sections and rules. The **Advanced** tab holds
the same definition as raw text for bulk edits and copying between orgs —
switching back to Rules re-reads whatever is there. Everything the rest of
this manual describes is what the form writes for you, so it is still worth
knowing what each key means.

## Adding a new document type

Everything above is about editing an **existing** IDP Mapping Set's
Definition. The Configurator's Save button only updates a record that
already exists — it has no "create" button, on purpose: a new mapping set
is a new custom metadata record, and that first record has to be created in
Setup once. After that, it behaves exactly like every other document type
described in this manual.

1. **Setup → Custom Metadata Types → IDP Mapping Set → Manage Records → New.**
   Fill in:

    | Field                            | What to put                                                                                                                                                                                                 |
    | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
    | `Label` / `IDP Mapping Set Name` | A human label and a DeveloperName — pick the DeveloperName carefully, it is the identity every caller (Flow, LWC, batch) uses to run this document type, and renaming it later means updating every caller. |
    | `Active__c`                      | Checked. An inactive set behaves as if it does not exist.                                                                                                                                                   |
    | `Default_Mode__c`                | `Extraction`, `Compliance` or `Preview` — the mode a run uses when nobody names one explicitly. `Extraction` is the usual choice.                                                                           |
    | `Definition__c`                  | `{"sections": []}` to start. You will fill this in from the Configurator next, not here — hand-writing is the escape hatch, not the front door.                                                             |
    | `JSON_Source_Field__c`           | Leave blank unless this document type will run from `IdpBatchProcessor`. If it will, `Object.Field` naming the long-text field that holds the stored JSON, e.g. `Case.Extracted_JSON__c`.                   |
    | `Processed_Marker_Field__c`      | Leave blank unless batching. A Datetime field on the same object as `JSON_Source_Field__c`, stamped after a document runs so a rerun of the batch skips it.                                                 |
    | `Finding_Handler__c`             | Leave blank unless a Compliance run should notify someone automatically. Apex class name implementing `IIdpFindingHandler`.                                                                                 |
    | `Description__c`                 | What this document type is, for the list in the Configurator. Not read by the engine.                                                                                                                       |

    Only `Label`, the DeveloperName, `Active__c` and `Definition__c` are
    needed to get started; the rest can be added later without touching what
    is already configured.

2. **App Launcher → IDP Configuration.** The new document type now appears
   in the left-hand list — empty, with no sections. From here on, use the
   Rules tab (or the Advanced tab) exactly as described in the rest of this
   manual: **Add section**, fill in the target object, **Add rule** per
   field, **Check**, **Save**.

3. **Point a file or a record at it.** The mapping set is only reachable
   once something calls it by name — `IdpMappingController.apply()` /
   `preview()` from `fileJsonReview`, the `Apply IDP Mapping Set` invocable
   from Flow, or `IdpBatchProcessor` if you filled in `JSON_Source_Field__c`.
   None of that is configuration; see
   [IDP_MAPPING.md](IDP_MAPPING.md) for how each caller is wired up.

New document types are also just files: everything in
`force-app/idp/examples/*/customMetadata` is a real `IDP_Mapping_Set__mdt`
record checked into source, so copying one of those and changing the
DeveloperName, the sections and the target objects is usually faster than
starting from an empty Definition.

## The shape of it

Everything hangs off a list of sections, and every section holds its own rules:

```json
{
    "sections": [
        {
            "name": "Estate_Intake_Case",
            "label": "Estate Intake: Case",
            "sectionType": "Fixed",
            "targetObject": "Case",
            "rules": [
                {
                    "name": "Estate_Intake_Applicant_Email",
                    "label": "Estate Intake: Applicant Email",
                    "jsonPath": "applicant.email",
                    "targetField": "SuppliedEmail",
                    "overwritePolicy": "Always"
                }
            ]
        }
    ]
}
```

Read that as a sentence: _in the Estate Intake document, there is a region that
fills in a Case; in that region, the value at `applicant.email` goes into the
Case's `SuppliedEmail` field, overwriting whatever is there._

Only a handful of keys are ever required. **Every key not listed in the tables
below is a mistake**, and the engine screens for them before it loads anything:
a misspelled `jsonPaths` is not a rule that quietly does nothing, it is an
error naming the key and the rule it is on. Nothing loads until you fix it,
because a definition the engine only partly understands is worse than one it
refuses.

## Sections — regions of a document

A section is a part of the document that fills in one kind of record. A form
that updates a Case and its Account has two sections. An invoice with a header
and a table of line items has two sections: one Fixed, one Repeating.

| Key             | Required         | What it means                                                                                                                                        |
| --------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`          | yes              | The section's identity, unique within the document type. Letters, numbers and underscores. Used in error messages and by `parentSection`.            |
| `label`         | no               | A human name for messages. Defaults to `name`.                                                                                                       |
| `sectionType`   | no               | `Fixed` (default) writes one record. `Repeating` walks a list of rows.                                                                               |
| `targetObject`  | yes              | API name of the object this section writes to — `Case`, `Account`, `Asset`, `Claim__c`. Must exist, or the section and all its rules are skipped.    |
| `rules`         | yes, in practice | The list of fields to fill. A section with no rules does nothing.                                                                                    |
| `recordFilter`  | no               | Extra SOQL `WHERE` fragment narrowing which record is used. Overrides a rule's `anchorFilter`.                                                       |
| `active`        | no               | `false` switches the whole section off without deleting it. Defaults to on.                                                                          |
| `rowPath`       | Repeating only   | Path to the list of rows in the document, e.g. `Details`.                                                                                            |
| `matchField`    | Repeating only   | The field each row is found by, e.g. `SerialNumber`. Any queryable field — it does **not** have to be an External Id.                                |
| `matchValue`    | Repeating only   | A template building each row's key. See [tokens](#tokens-in-matchvalue).                                                                             |
| `unmatchedRows` | Repeating only   | `Create` makes the section **create** a row no record matched, instead of only reporting it. Extraction and Preview only — Compliance never creates. |
| `whenNoAnchor`  | Fixed only       | `Create` makes the section **create** its target record when none is reachable, linked to the first resolved record it looks up to.                  |
| `parentSection` | no               | Name of another section whose record constrains this one's rows. Leave it out and the engine finds the relationship from the schema.                 |

### A repeating section

```json
{
    "name": "Invoice_Intake_Lines",
    "label": "Invoice Intake: Lines",
    "sectionType": "Repeating",
    "targetObject": "Asset",
    "rowPath": "Details",
    "matchField": "SerialNumber",
    "matchValue": "INV-{json:Invoice}-{row:number}",
    "rules": [
        {
            "name": "Invoice_Intake_Line_Quantity",
            "jsonPath": "Quantity",
            "targetField": "Quantity",
            "overwritePolicy": "Always"
        }
    ]
}
```

Inside a repeating section, each rule's `jsonPath` is read **relative to the
current row** — `Quantity`, not `Details[0].Quantity`. That is why the rule
count stays the same whether the invoice has two lines or two hundred.

Rows are **matched and updated** by default. A row whose key finds no record
is reported back as an unmatched row, which is information, not a failure.
Add `"unmatchedRows": "Create"` to the section and the engine instead
creates the missing row — match key and parent link filled in, the
section's rules applied, everything in the run's single insert. Creation
only happens in Extraction (Preview reports what would be created;
Compliance never creates), and a creation the database refuses — a missing
required field, a validation rule — comes back as a `DML_FAILED` finding on
that row.

### Tokens in `matchValue`

| Token          | Reads                                 |
| -------------- | ------------------------------------- |
| `{json:path}`  | A value from the document root.       |
| `{row:path}`   | A value from the row being processed. |
| `{row:index}`  | Position of the row, counting from 0. |
| `{row:number}` | Position of the row, counting from 1. |

Whole numbers render without a decimal point, so the second line is `2`, never
`2.0`.

## Rules — one field each

One rule moves one value from the document into one field.

| Key                | Required            | What it means                                                                                                                                                                                                                                |
| ------------------ | ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`             | yes                 | The rule's identity, unique within the document type. Appears in every message about it.                                                                                                                                                     |
| `label`            | no                  | A human name for messages. Defaults to `name`.                                                                                                                                                                                               |
| `jsonPath`         | yes                 | Where to read from, as a dot path: `applicant.email`, `parties[0].name`. Relative to the row in a Repeating section.                                                                                                                         |
| `targetField`      | yes                 | The field to write, e.g. `SuppliedEmail`. `Case.SuppliedEmail` is accepted too — the object part is ignored, since the section already decided the object.                                                                                   |
| `valueTypeName`    | no                  | Name of an IDP Value Type that parses the raw text (money, dates, phone numbers). Leave it out and a strict type is derived from the field itself.                                                                                           |
| `overwritePolicy`  | no                  | `Always` replaces what is there. `Only if blank` fills gaps and never overwrites a human's work.                                                                                                                                             |
| `mode`             | no                  | `Extraction` writes the value. `Compliance` compares it and reports instead of writing. `Custom` hands the parsed value to the Apex class in `handlerClass`. Leave it out to follow the run's mode.                                          |
| `handlerClass`     | with `mode: Custom` | Apex class implementing `IIdpFieldHandler`. It receives the parsed value with its grade and confidence, and mutates the record in memory — the engine still performs the single, permission-checked save. Skipped in Preview, which says so. |
| `minGrade`         | no                  | Lowest parse quality allowed to write. `Exact` means only a cleanly parsed value counts. The default, `Inferred`, blocks only genuinely ambiguous readings.                                                                                  |
| `minConfidence`    | no                  | A number between 0 and 1. If the document states a confidence for the value, anything below this is not written.                                                                                                                             |
| `confidenceWeight` | no                  | Relative weight of this field in the document confidence score. Leave it out (or 0) for "not interesting". The score is the weighted average of the stated confidences of the weighted fields, on the Result as `documentConfidence`.        |
| `required`         | no                  | `true` means a document missing this path is an error worth someone's attention, not a silent skip.                                                                                                                                          |
| `anchorFilter`     | no                  | Extra SOQL `WHERE` fragment narrowing which record the value lands on. The section's `recordFilter` beats it.                                                                                                                                |
| `active`           | no                  | `false` switches the rule off without deleting it. Defaults to on.                                                                                                                                                                           |

### Leaving out what you do not need

Every optional key can simply be absent. These two rules behave identically:

```json
{
    "name": "Email",
    "jsonPath": "applicant.email",
    "targetField": "SuppliedEmail"
}
```

```json
{
    "name": "Email",
    "jsonPath": "applicant.email",
    "targetField": "SuppliedEmail",
    "valueTypeName": null,
    "mode": null,
    "anchorFilter": null
}
```

The short one is better. Write what you mean and leave the rest out.

## Value maps — translating wording

When a document says "Pty Ltd" and your picklist says "Private Company",
that translation lives on the **IDP Value Type** record, in its
`Value_Map_Entries__c` field — not in the document type's Definition. One
dictionary serves every document type that references it.

```json
{
    "entries": [
        { "fromText": "Pty Ltd", "toValue": "Private Company" },
        {
            "fromText": "(?i)\\(?pty\\.?\\)?\\s*ltd\\.?",
            "toValue": "Private Company",
            "matchStyle": "Regex"
        },
        {
            "fromText": "Close Corp",
            "toValue": "Close Corporation",
            "active": false
        }
    ]
}
```

| Key          | Required | What it means                                                                                                         |
| ------------ | -------- | --------------------------------------------------------------------------------------------------------------------- |
| `fromText`   | yes      | What the document says.                                                                                               |
| `toValue`    | yes      | What to store instead.                                                                                                |
| `matchStyle` | no       | `Normalized` (default) ignores case, spacing and accents. `Exact` is literal. `Regex` treats `fromText` as a pattern. |
| `active`     | no       | `false` retires an entry without deleting it.                                                                         |

Wording the dictionary does not cover **fails loudly**. That is deliberate: a
controlled field should never quietly receive free text nobody approved.

## Common jobs

### Add a field to an existing document type

Find the section that writes to the right object, and add one rule to its
`rules` list:

```json
{
    "name": "Estate_Intake_Applicant_Reference",
    "label": "Estate Intake: Applicant Reference",
    "jsonPath": "applicant.reference",
    "targetField": "Application_Reference__c",
    "overwritePolicy": "Only if blank"
}
```

Press **Check**. If the field name is wrong you will be told before you save.

### Stop a rule without deleting it

Add `"active": false`. The rule stays in place with its history intact, and
switching it back on is a one-word edit. Better than deleting when you are
diagnosing something.

### Protect what people have typed by hand

Use `"overwritePolicy": "Only if blank"`. The engine will fill an empty field
but never overwrite a value someone entered.

### Only accept a confident reading

```json
{ "minGrade": "Exact", "minConfidence": 0.9 }
```

`minGrade` is about how cleanly the text parsed; `minConfidence` is about how
sure the extraction was. They are independent, and using both is normal for
figures that matter, like amounts.

### Check a document instead of updating it

Set `"mode": "Compliance"` on a rule. It compares the document against what is
already stored and reports agreement, disagreement or absence, without writing
anything. One document type can extract some fields and verify others.

## When something is wrong

The engine never throws away a whole document type because one line is wrong.
It reports the problem, disables the smallest piece it can, and runs the rest.

| What you did                                          | What happens                                                                      |
| ----------------------------------------------------- | --------------------------------------------------------------------------------- |
| Misspelled a key, or broke the JSON syntax            | **Nothing loads.** The whole document type stops, because nothing else is honest. |
| Named an object that does not exist                   | That section and all of its rules are skipped.                                    |
| Named a field that does not exist                     | That one rule is skipped.                                                         |
| Left out `jsonPath` or `targetField`                  | That one rule is skipped.                                                         |
| Named a value type that does not exist                | That one rule is skipped.                                                         |
| Used a `mode` other than the three valid ones         | That one rule is skipped.                                                         |
| `mode: Custom` with a missing or wrong `handlerClass` | That one rule is skipped, with the reason named.                                  |
| `unmatchedRows` / `whenNoAnchor` misused              | The key is ignored and you are told why; the section still runs.                  |
| Pointed `parentSection` at nothing real               | The section still runs; the parent constraint is dropped.                         |
| Named a locale or region nobody seeded                | The rule still runs, with reduced parsing. You are told which.                    |

Every one of these appears in the Configurator when you press **Check**, and
again as a configuration finding on any run. The **Save** button refuses
outright on the errors and lets the warnings through, because a warning is
often a deliberate staging step.

### The one that catches people

Field names are no longer picked from a list, so nothing stops you typing
`SuppliedEmial`. The engine checks every object and field name against the real
schema when it loads, so you will find out — but you find out on **Check** or
on the first run, not the instant you type it. Press Check before you save. It
costs a second.

The same applies in reverse: if someone deletes a Salesforce field a rule
writes to, the deletion is no longer blocked. The rule starts reporting that
its field is unknown.

## Rules of thumb

- **Press Check before Save.** It runs the same code a real document run does.
- **Keep `name` stable.** It is how findings, logs and support conversations
  refer to a rule. Rename the `label` freely; think twice about the `name`.
- **One section per object, usually.** Two sections writing the same object is
  legal but rarely what you meant.
- **Prefer `Only if blank`** unless the document is genuinely more trustworthy
  than the humans using the system.
- **Do not paste in keys you saw elsewhere.** If it is not in the tables above,
  it is not a key, and it will stop the whole document type from loading.
- **Reach for a value type** rather than post-processing. Dates, money and
  phone numbers are parsed and graded properly by the value type layer; a rule
  that writes raw text into a Date field is a rule that will fail on the first
  document written in another format.

## Recipes

Three worked examples, start to finish. Each one is a job you would actually
be asked to do, not a feature tour.

### Recipe 1 — Onboard a new document type from scratch

**The ask:** "We get a Proof of Address as a PDF. It has an address and an
issue date. Put it on the Case."

1. **Setup → Custom Metadata Types → IDP Mapping Set → New** (see
   [Adding a new document type](#adding-a-new-document-type)):
    - `Label`: `Proof of Address`
    - DeveloperName: `Proof_Of_Address`
    - `Active__c`: checked
    - `Default_Mode__c`: `Extraction`
    - `Definition__c`: `{"sections": []}`
2. **App Launcher → IDP Configuration**, select **Proof of Address**,
   **Add section**:
    - Name: `Address_Details`, Region type: `Fixed`, Fills in: `Case`
3. **Add rule** twice:
    ```json
    {
        "name": "POA_Address",
        "jsonPath": "document.address",
        "targetField": "Description",
        "overwritePolicy": "Only if blank"
    }
    ```
    ```json
    {
        "name": "POA_Issue_Date",
        "jsonPath": "document.issueDate",
        "targetField": "Application_Signed_Date__c",
        "valueTypeName": "AO_Date_ZA"
    }
    ```
    (Reusing an existing value type — `AO_Date_ZA` from the
    [business-account-opening example](force-app/idp/examples/business-account-opening) —
    rather than inventing a new one for the same date format. One value type
    can serve every document type that shares its formatting.)
4. **Check.** Fix anything it names — a typo in `targetField` is the usual
   culprit.
5. **Save.** Wait for "Saved" in the status pill; it is a metadata
   deployment, not an instant write.
6. Try it: paste a sample `{"document": {"address": "12 Long St, Cape
Town", "issueDate": "04/03/2026"}}` into `fileJsonReview`'s Source JSON
   against a Case with a linked file, and confirm the fields land.

### Recipe 2 — Stop losing unmatched invoice lines: create instead of report

**The ask:** "Consolidated Statement" (see the
[example](force-app/idp/examples/consolidated-statement)) reports a
`ROW_UNMATCHED` finding whenever the statement lists a product the org has
no `Asset` for yet — a new account the customer opened since the last
statement. The admin wants those rows created instead of just flagged.

This is **ENG-2** — added recently, so the section-level key may be new to
you even if you know the rest of the engine.

1. Open the **Consolidated_Statement** mapping set, find the
   **Consolidated_Statement_Holdings** section (Repeating, target `Asset`).
2. On the **Advanced** tab (there is no form control for this key yet —
   type it directly), add one key to the section:
    ```json
    {
        "name": "Consolidated_Statement_Holdings",
        "sectionType": "Repeating",
        "targetObject": "Asset",
        "rowPath": "holdings",
        "matchField": "Product_Account_Number__c",
        "matchValue": "{row:accountNumber}",
        "recordFilter": "Account_Status__c != 'Closed'",
        "parentSection": "Consolidated_Statement_Header",
        "unmatchedRows": "Create",
        "rules": [/* unchanged */]
    }
    ```
3. **Check**, then **Save**.
4. Run **Preview** against a statement with a product the org does not
   have yet. The unmatched row now appears in `plannedChanges` with
   `isNew: true` instead of only in `unmatchedRowKeys` — the plan is honest
   about what will be created before anyone commits to it.
5. Run for real. The created row's `Result.rowsCreated` and
   `createdRecordIds` account for it, and a `ROW_CREATED` finding replaces
   the `ROW_UNMATCHED` one.

Worth remembering: this only fires in Extraction (Preview reports it,
Compliance never creates), and a row the database refuses — a missing
required field on `Asset`, say — comes back as a `DML_FAILED` finding
instead of silently vanishing.

### Recipe 3 — Weight the fields that matter for a document confidence score

**The ask:** "Letters of Executorship" (see the
[example](force-app/idp/examples/letters-of-executorship)) extracts nine
fields. Compliance wants one number per document saying how much to trust
the OCR, weighted toward the fields that actually matter — the estate
number most of all — not toward whichever field happened to have the
clearest handwriting.

This is **ENG-9** — the `confidenceWeight` rule key and
`Result.documentConfidence`, both added recently.

1. Open the **Letters_Of_Executorship** mapping set. On the rule for
   `letters.estateNumber` (the estate's identity — weight it highest), add:
    ```json
    { "confidenceWeight": 3 }
    ```
2. On the two identity-number rules (`executor.identityNumber`,
   `deceased.identityNumber`) and the two date rules
   (`letters.issuedDate`, `deceased.dateOfDeath`), add lighter weights:
    ```json
    { "confidenceWeight": 2 }
    ```
    ```json
    { "confidenceWeight": 1 }
    ```
    Leave the name and picklist rules unweighted — they are easy for a
    human to eyeball, so their OCR confidence is not what should decide
    whether someone looks twice.
3. **Check**, **Save**.
4. Feed the engine JSON where the weighted paths carry confidence
   envelopes:
    ```json
    {
        "letters": {
            "estateNumber": { "value": "004521/2026", "confidence": 0.98 },
            "issuedDate": { "value": "08/04/2026", "confidence": 0.91 }
        }
    }
    ```
    `Result.documentConfidence` comes back as the weighted average —
    `Σ(weight × confidence) / Σ(weight)` — of every weighted field that
    carried a confidence. A weighted field the document does not annotate
    is excluded from both sums, not counted as 0, so a service that only
    annotates some fields does not tank the score by itself.
5. Feed it a plain document with no confidence envelopes at all, and
   `documentConfidence` comes back **null**, not zero — "no score" and "a
   bad score" have to stay distinguishable, or a null gets misread as a
   failing document.

The full worked version — six rules, one confidence-annotated sample file,
and the arithmetic spelled out — is in
[the example's README](force-app/idp/examples/letters-of-executorship/README.md#the-document-confidence-score).

## Related documents

- [IDP_MAPPING.md](IDP_MAPPING.md) — how the engine works: value types, grades,
  compliance, batch processing, calling it from Flow and LWC.
- Sample configurations live under `force-app/idp/examples`, each with its own
  README and a document to try it on.
