# JSON Field Mapping Engine

Once a user has reviewed a document and its extracted JSON (typically in the
[fileJsonReview](DOC_PREVIEWER.md) component), something has to get that data
into Salesforce. That is what this engine does, in one of two modes:

- **Data Extraction**, the default, writes the extracted values into the
  records reachable from the file.
- **Compliance Check** writes nothing at all. It compares the extracted
  values against what is already stored and reports the differences,
  optionally handing them to a custom Apex action.

Which JSON path maps to which field is configuration rather than code:
each mapping is a `JSON_Field_Mapping__mdt` record, so adding or changing
one is an admin task. Documents that pair fixed header and footer regions
with a repeating detail band are handled by declaring
[sections](#sections-fixed-and-repeating-regions).

```
  the file                        records found by walking the schema
  ─────────────────────────       ───────────────────────────────────
  ContentDocument
        │  ContentDocumentLink
        ▼
   Document__c  ──lookups──►  Case  ──►  Account
      (hub)                     └───►  Estate_Case__c, Opportunity,
                                       any custom object…

  reviewed JSON ──►  JsonMappingService  ──►  Extraction: writes the values
                     rules from                    │
                     JSON_Field_Mapping__mdt       └─►  Compliance: compares
                                                        them and reports
                                                        mismatches to an
                                                        IComplianceMismatchHandler
```

The review components stay **storage-agnostic**. `fileJsonReview` and
`jsonForm` do nothing but emit the reviewed JSON; persistence belongs to
whoever hosts them, whether that is a Screen Flow calling the invocable
action or a parent LWC like the bundled `fileJsonReviewMappingDemo`.

## Components

| Component                    | Type                 | Role                                                                                                                         |
| ---------------------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `JSON_Field_Mapping__mdt`    | Custom Metadata Type | Declares the mapping rules.                                                                                                  |
| `JSON_Mapping_Section__mdt`  | Custom Metadata Type | Declares a fixed or repeating region of the document that rules attach to.                                                   |
| `JsonFilterBinder`           | Apex                 | Resolves `{json:…}` / `{row:…}` tokens in filters and key templates, binding document values rather than concatenating them. |
| `JsonMappingService`         | Apex                 | Orchestrator. Entry points: `apply` (`@InvocableMethod`, for Flow) and `applyMappings` (`@AuraEnabled`, for LWCs).           |
| `JsonMappingSelector`        | Apex                 | Loads the active rules of one mapping set.                                                                                   |
| `DocumentContextResolver`    | Apex                 | Turns a `contentDocumentId` into a map of reachable records, keyed by object API name.                                       |
| `JsonPathReader`             | Apex                 | Dot-notation JSON path extraction, including array indexes (`beneficiaries[0].name`).                                        |
| `FieldValueCoercer`          | Apex                 | Describe-driven type conversion: text, number, boolean, date, datetime, picklist.                                            |
| `IComplianceMismatchHandler` | Apex interface       | Contract for custom mismatch actions in Compliance mode.                                                                     |
| `ComplianceTaskHandler`      | Apex                 | Sample handler that creates a review Task listing the mismatches.                                                            |
| `JsonMappingServiceTest`     | Apex test            | Coverage for all of the above.                                                                                               |
| `fileJsonReviewMappingDemo`  | LWC                  | Example host wiring `fileJsonReview` to the engine.                                                                          |

## Configuring mappings

Every `JSON_Field_Mapping__mdt` record describes one rule:

| Field                 | Meaning                                                                                                                                   | Example                 |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| `Mapping_Set__c`      | Groups rules by use case. One set is applied per call.                                                                                    | `Estate_Intake`         |
| `Section__c`          | Section this rule belongs to. Blank means a standalone rule against a record reachable from the file — the original behaviour, unchanged. | `Lines`                 |
| `JSON_Path__c`        | Dot path into the JSON. Use `[n]` to index arrays.                                                                                        | `applicant.dateOfBirth` |
| `Target_Object__c`    | API name of the object to write to. It has to be reachable from the file (see below).                                                     | `Estate_Case__c`        |
| `Target_Field__c`     | API name of the field that receives the value.                                                                                            | `Date_of_Birth__c`      |
| `Overwrite_Policy__c` | `Always` or `Only if blank`. Extraction mode only.                                                                                        | `Only if blank`         |
| `Transform__c`        | Optional format hint. For Date fields: `yyyy-MM-dd` (the default), `dd/MM/yyyy` or `MM/dd/yyyy`.                                          | `dd/MM/yyyy`            |
| `Mode__c`             | Optional per-rule override of the run mode, `Extraction` or `Compliance`. Leave blank to inherit the run's.                               | `Compliance`            |
| `Anchor_Filter__c`    | Optional filter narrowing which record the target object resolves to (see below).                                                         | `Status__c = 'Active'`  |
| `Active__c`           | Untick to disable a rule without deleting it.                                                                                             | ✓                       |

Four sample records ship with the project under the `Estate_Intake` mapping
set. They target standard fields only (`Case.SuppliedName`,
`Case.SuppliedEmail`, `Case.Description` and `Account.Phone`) so the demo
works in any org.

## Sections: fixed and repeating regions

Most business documents are a header and footer wrapped around a repeating
band — invoice lines, statement transactions, payslip earnings, policy
coverages, estate asset lines. A `JSON_Mapping_Section__mdt` record declares
one such region, and rules attach to it through `Section__c`:

| Field               | Meaning                                                                                   | Example                           |
| ------------------- | ----------------------------------------------------------------------------------------- | --------------------------------- |
| `Mapping_Set__c`    | Must match the mapping set of the rules that reference it.                                | `Invoice_Intake`                  |
| `Section_Name__c`   | The name rules point at.                                                                  | `Lines`                           |
| `Section_Type__c`   | `Fixed` (one record) or `Repeating` (one record per row).                                 | `Repeating`                       |
| `Target_Object__c`  | Object the section writes to. Attached rules inherit it.                                  | `Asset`                           |
| `Row_Path__c`       | Repeating only: JSON path to the array of rows.                                           | `Details`                         |
| `Match_Field__c`    | Repeating only: the field identifying a row.                                              | `SerialNumber`                    |
| `Match_Value__c`    | Repeating only: template producing each row's key.                                        | `INV-{json:Invoice}-{row:number}` |
| `Record_Filter__c`  | Optional extra WHERE fragment. Supersedes a rule's `Anchor_Filter__c`.                    | `Status != 'Obsolete'`            |
| `Parent_Section__c` | Section whose record constrains this one. Blank discovers the constraint from the schema. | `Header`                          |
| `Active__c`         | Disables the section and every rule on it.                                                | ✓                                 |

A **Fixed** section is the existing single-record behaviour with the object
and filter declared once instead of repeated on every rule. A **Repeating**
section iterates `Row_Path__c` and reads each rule's `JSON_Path__c` relative
to the current row, so the rule count stays constant no matter how many rows
the document has.

The invoice in `Invoice_Intake` ships as a working sample against standard
`Asset` fields, so it runs in any org:

```
Section  Lines: Repeating, Asset, Row_Path=Details,
                Match_Field=SerialNumber,
                Match_Value=INV-{json:Invoice}-{row:number}

Rule     Section=Lines, JSON_Path=Quantity     → Quantity
Rule     Section=Lines, JSON_Path=Description  → Name
Rule     Section=Lines, JSON_Path=Subtotal     → Price
```

### Match values

`Match_Value__c` builds the key each row is looked up by. Four token forms
are available: `{json:path}` reads from the document root, `{row:path}` from
the current row, `{row:index}` is the 0-based position and `{row:number}` the
1-based one. Whole numbers render without a decimal point, so line 2 is
`2` rather than `2.0`.

`Match_Field__c` does **not** have to be an External Id. Rows are matched with
a SOQL query, so any queryable field works — a serial number, a reference
code, a line number. A true External Id only becomes necessary if the engine
later gains the ability to create rows.

### What this version does and does not do

Rows are **matched and updated, never created**. A document row whose key
finds no record is reported in `Result.unmatchedRowKeys`, which is data
rather than an error, and nothing is inserted or deleted. Record creation
and reconciliation of stale rows are deliberately left to a later version;
the schema already carries `Parent_Section__c` so that nesting can arrive
without a migration.

Two safeguards are worth knowing about. Rows are constrained to the parent
record resolved from the file, so a key that is only unique within one
account cannot reach another account's rows. And if two document rows render
the same key, the second is skipped and reported rather than silently
overwriting the first.

Cost is one query and one DML per run regardless of row count: a
200-line statement costs the same as a 2-line invoice.

### Compliance over rows

Compliance works the same way on a repeating section, comparing without
writing. Each mismatch additionally carries `sectionName`, `rowIndex` and
`rowKey`, so the report identifies which line of the document disagrees
rather than just which field.

## Reachable objects

`Target_Object__c` accepts any object, standard or custom: Case, Account,
Opportunity, `Estate_Case__c`, `My_Object__c` and so on. Nothing is
hard-coded, because `DocumentContextResolver` works out the path from the
file to each target at run time:

1. **Roots.** Every record the file is linked to through
   `ContentDocumentLink`. Normally that is the `Document__c` ECM hub, but a
   file linked directly to any record works too. System links such as User,
   Group and library entries are ignored. The hub's own lookups are followed
   straight away, so its parents (Case, Account, Opportunity, and the rest)
   are available as stepping stones even when no rule targets them.
2. **Parent hops.** An already-resolved record holds a lookup to the target,
   as in `Document__c.Case__c` → Case or `Case.AccountId` → Account.
3. **Child hops.** The target holds a lookup back to a resolved record, as
   in `Estate_Case__c.Case__c = :caseId`. These are ordered
   `CreatedDate DESC`, so the most recent child wins.

The resolver repeats these passes (up to three) until every target is
resolved or a pass makes no progress. Each resolved record costs one query:
the objects your rules target, plus the hub's immediate parents, which are
fetched regardless so they can serve as stepping stones.

Lookups themselves are discovered from the schema. A field named
`<Object>__c` or `<Object>Id` is preferred, so `Case__c` and `AccountId` are
picked up automatically. Failing that, the resolver accepts the single
reference field pointing at that object; if there are several and none uses
the conventional name, it treats the relationship as ambiguous and resolves
nothing. Since no object is referenced at compile time, the classes deploy
to any org, and a rule whose target cannot be reached is reported in
`errors` rather than failing the run.

### Anchor filters

Some hops can legitimately match more than one record, most often a child
hop where a Case has several `Estate_Case__c` children. `Anchor_Filter__c`
narrows the search by contributing an extra condition, ANDed onto the
hop's own:

```
Status__c = 'Active' AND Policy_Number__c = {json:policy.number}
```

Constants are written literally, which is safe because the fragment is
metadata controlled by whoever deploys it. Values coming from the reviewed
document are different: a `{json:path}` token is replaced with a bind
variable holding the value read at that path, so document content is bound
rather than concatenated into the query and cannot inject SOQL.

Every anchor query is `LIMIT 1`. If no filter is supplied, or several
records still match after filtering, a child hop settles on the newest
record. The filter applies wherever that object is queried during
resolution, and when several rules for the same object carry a filter, the
first non-blank one in DeveloperName order is used.

## Modes

The run mode is passed to the service through its `mode` parameter and
defaults to `Extraction`. A rule's `Mode__c` overrides it for that field,
which lets a single mapping set extract new data while verifying identity
fields in the same call.

**Data Extraction** coerces each extracted value to the target field's type
and updates the records, honoring `Overwrite_Policy__c`.

**Compliance Check** performs no DML whatsoever. It compares each extracted
value with the stored one, and the comparison is deliberately forgiving
about formatting but not about content:

- Text is normalized first: trimmed, internal whitespace collapsed and
  compared case-insensitively, because OCR output rarely matches stored
  casing exactly.
- Numbers are compared by value, so `1,234.50` and `1234.5` agree. Dates and
  booleans likewise compare by value.
- A blank stored field counts as a mismatch. An empty field cannot confirm
  what the document says.
- A JSON path missing from the document is skipped, exactly as in
  Extraction.

Differences are collected into `Result.mismatches`, each carrying
`objectName`, `recordId`, `fieldName`, `jsonPath`, `extractedValue` and
`actualValue`, and they clear `Result.compliant`. They are data rather than
failures, so `Result.success` stays true.

### Custom mismatch action

If a Compliance run finds mismatches and the caller passed a
`mismatchHandler` class name, the service instantiates that class with
`Type.forName` (the same dependency-injection convention the LQC uses for
its `storageClass`) and calls:

```apex
public interface IComplianceMismatchHandler {
  void handle(JsonMappingService.ComplianceReport report);
  // report: contentDocumentId, mappingSetName, mismatches
}
```

The bundled `ComplianceTaskHandler` creates a _Review compliance mismatches_
Task listing every difference, on the resolved Case where there is one and
otherwise on the first mismatched record. Handlers run inside the same
transaction; if one throws, the failure is reported in `Result.errors`
without rolling back extraction updates from that run. Note that the
mismatches come back on the `Result` regardless, so the hosting Flow or LWC
can react (warn the user, block the submit) whether or not a handler is
configured.

## Error handling

The engine is built around partial success. Rule-level problems, such as an
unreachable object, an unknown field, a value that cannot be converted, an
inactive picklist value, or a bad mode or handler name, are collected into
`Result.errors` while every other field carries on processing. DML runs with
`Database.update(records, false)` for the same reason. A JSON path that is
simply absent from the document is not an error; that rule is skipped
quietly.

Field-level security is enforced on both sides of the operation: anchors are
queried in `USER_MODE`, and updates pass through
`Security.stripInaccessible(AccessType.UPDATABLE, …)` before they are saved.

`Result` carries `success` (no errors at all), `compliant` (no mismatches),
`fieldsApplied`, `fieldsCompared`, `rowsMatched`, `rowsUpdated`,
`unmatchedRowKeys`, `updatedRecordIds`, `mismatches` and `errors`.

## Usage from a Screen Flow

1. Add a screen element hosting **fileJsonReview**, giving it the
   `contentDocumentId` and the `jsonInput` from your OCR/IDP response so the
   user can review and correct the data.
2. Follow it with the **Apply JSON Field Mappings** action:
   - _Content Document Id_ → the same `contentDocumentId`
   - _JSON String_ → the screen component's `jsonOutput`
   - _Mapping Set Name_ → for example `Estate_Intake`
   - _Mode_ → `Extraction` (default) or `Compliance`
   - _Mismatch Handler Class_ → optional, for example `ComplianceTaskHandler`
3. Branch on `success` and `compliant`, then show `errors` or `mismatches`
   on a result screen.

## Usage from a parent LWC

`fileJsonReviewMappingDemo` is the reference implementation and can be
dropped onto an App, Home or Record page. It hosts `c-file-json-review` and,
when the user submits, calls the engine imperatively:

```js
import applyMappings from '@salesforce/apex/JsonMappingService.applyMappings';

handleJsonSubmit(event) {
    applyMappings({
        contentDocumentId: this.contentDocumentId,
        jsonString: event.detail.jsonString,
        mappingSetName: this.mappingSetName,
        mode: this.mode, // 'Extraction' or 'Compliance'
        mismatchHandler: this.mismatchHandler || null
    }).then((result) => { /* toast + show result.errors / result.mismatches */ });
}
```

To see it work, point _Content Document Id_ at a file linked to a Case, or
to a `Document__c` that looks up to one, and press **Save to Salesforce**.
The sample JSON's applicant name and email and the estate description land
on the Case, while the phone lands on the Account if its Phone is blank.
Switch the _Mode_ property to `Compliance`, optionally naming
`ComplianceTaskHandler` as the handler, and the same button becomes
**Check compliance**: nothing is written, and any differences appear in a
table underneath the review pane.

## Extending

- **A new use case** needs no code. Create rules under a new
  `Mapping_Set__c` value and pass that name.
- **A document with detail lines** needs no code either: add a Repeating
  section and attach rules to it. The same three rules serve two lines or
  two hundred.
- **A new target object** also needs no code, as long as it is reachable
  from the file through a lookup the resolver can discover. Point
  `Target_Object__c` at it. Only a genuinely new traversal pattern, rather
  than a new object, calls for changes in `DocumentContextResolver`.
- **A new transform** means extending `FieldValueCoercer` and documenting
  the hint value it recognizes.
- **A new mismatch action** means implementing `IComplianceMismatchHandler`,
  using `ComplianceTaskHandler` as a template, and passing the class name as
  `mismatchHandler`. The engine itself does not change.
- **Audit and reprocessing**: persist the raw JSON somewhere (on
  `Document__c`, for instance) before calling the service, so mappings can
  be re-run later when the rules change.

---

_Related docs: [README.md](README.md) (documentation index),
[DOC_PREVIEWER.md](DOC_PREVIEWER.md) (the `fileJsonReview` previewer),
[JSON_FORM.md](JSON_FORM.md) (the `jsonForm` child component)._
