# Configuring a document type

This is the manual for the JSON that tells the IDP engine what to pull out of
a document and where to put it. If you are adding a field to an existing
document type, changing which record a value lands on, or onboarding a new
document type entirely, this is the file you need.

You do not need to be a developer to use it. You do need to be careful, because
this JSON is the thing the engine obeys.

**Contents**

- [Where the configuration lives](#where-the-configuration-lives)
- [The shape of it](#the-shape-of-it)
- [Sections — regions of a document](#sections--regions-of-a-document)
- [Rules — one field each](#rules--one-field-each)
- [Value maps — translating wording](#value-maps--translating-wording)
- [Common jobs](#common-jobs)
- [When something is wrong](#when-something-is-wrong)
- [Rules of thumb](#rules-of-thumb)

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

## Related documents

- [IDP_MAPPING.md](IDP_MAPPING.md) — how the engine works: value types, grades,
  compliance, batch processing, calling it from Flow and LWC.
- Sample configurations live under `force-app/idp/examples`, each with its own
  README and a document to try it on.
