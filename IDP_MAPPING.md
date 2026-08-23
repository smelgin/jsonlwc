# IDP Mapping Engine

Once a user has reviewed a document and its extracted JSON (typically in the
[fileJsonReview](DOC_PREVIEWER.md) component), something has to get that data
into Salesforce. That is what this engine does, in one of three modes:

- **Extraction**, the default, writes the extracted values into the records
  reachable from the document.
- **Compliance** writes nothing at all. It compares the extracted values
  against what is already stored — both sides canonicalized through the same
  value type, so formatting differences are never findings — and reports
  Match / Near / Mismatch per field.
- **Preview** runs the full Extraction pipeline but skips the final DML,
  returning the planned old → new change per field. It is how the review UI
  shows the user what will actually land before anything is written.

Everything is configuration rather than code — five custom metadata types
describe the document, and the engine is bulk-first: it processes a list of
documents per run, and its query count does not grow with the number of
rules, rows, or (for grouped work) documents.

```
 files or records                    records found by walking the schema
 ────────────────────────────       ───────────────────────────────────
 ContentDocument ──ContentDocumentLink──►  Document__c ──lookups──► Case ──► Account
      (or any record, seeded directly)        (hub)                   └──► Estate_Case__c, …

 reviewed JSON ──► IdpMappingEngine ──► Extraction: stages writes, ONE partial-success DML
                   config from                │
                   IDP_Mapping_Set__mdt       ├─► Compliance: canonicalizes BOTH sides,
                   + sections + rules         │   verdict Match / Near / Mismatch
                   + value types              └─► Preview: returns the write plan, no DML
```

The review components stay **storage-agnostic**. `fileJsonReview` and
`jsonForm` do nothing but emit the reviewed JSON; persistence belongs to
whoever hosts them — a Screen Flow calling the invocable action, a parent LWC
like the bundled `fileJsonReviewMappingDemo`, or `IdpBatchProcessor` with no
user at all.

## Contents

- [Ten Benefits and Capabilities](#ten-benefits-and-capabilities)
- [Components](#components)
- [Configuring a mapping set](#configuring-a-mapping-set)
- [Configuring rules — **IDP_CONFIGURATION.md**](IDP_CONFIGURATION.md)
- [Value types](#value-types)
- [Compliance: three-state, both sides canonicalized](#compliance-three-state-both-sides-canonicalized)
- [Sections: fixed and repeating regions](#sections-fixed-and-repeating-regions)
- [Reachable objects](#reachable-objects)
- [Results and findings](#results-and-findings)
- [Error handling and resilience](#error-handling-and-resilience)
- [Performance model](#performance-model)
- [Batch: reprocessing stored documents](#batch-reprocessing-stored-documents)
- [Usage from a Screen Flow](#usage-from-a-screen-flow)
- [Usage from a parent LWC](#usage-from-a-parent-lwc)
- [Extending](#extending)
- [Worked examples](#worked-examples)

## Ten Benefits and Capabilities

- **Documents become records, without code.** Point a JSON path at a field
  and the value lands where it belongs — adding a document type is admin
  configuration, not a development ticket.

- **Nothing is guessed silently.** Every value is graded Exact, Inferred,
  Ambiguous or Failed. Genuinely undecidable values are reported, never
  written — the class of error where a wrong number arrives without
  complaint is designed out.

- **Formats are declared once, not per rule.** Money, dates, phone numbers
  and picklist wording are described on reusable value types; forty rules
  share one definition, and changing a convention is one edit.

- **A human sees what will happen before it happens.** Preview mode runs the
  full pipeline with the write suppressed, showing current → new per field.
  Approval and persistence stop being able to disagree.

- **Verify without writing.** Compliance mode compares a signed document
  against the system of record and returns Match / Near / Mismatch — with
  formatting differences never counted as content differences.

- **Currency is treated as meaning, not decoration.** An amount in the wrong
  currency is refused rather than stored; 100 EUR never becomes 100 ZAR.

- **Runs unattended at volume.** The same engine drives a Screen Flow, an LWC
  or an overnight batch, and reruns are idempotent — finished work is never
  redone, deferred work retries itself.

- **Cost doesn't grow with the document.** Ten two-hundred-line statements
  cost what one two-line invoice costs; query consumption is flat against
  rules and rows alike.

- **Partial success at every level.** A bad rule, a bad value or a bad
  document is reported while everything else completes — one problem never
  takes the run down.

- **Misconfiguration fails before it ships.** Objects and fields are chosen
  from validated pickers, so a typo breaks the deployment rather than
  surfacing months later as a runtime error.

## Components

| Component                                          | Type           | Role                                                                                                        |
| -------------------------------------------------- | -------------- | ----------------------------------------------------------------------------------------------------------- |
| `IDP_Mapping_Set__mdt`                             | CMDT           | One use case: default mode, batch JSON source, default finding handler. Sections attach to it.              |
| `IDP_Value_Type__mdt`                              | CMDT           | How one semantic kind of value (money, phone, date, …) is parsed, compared and rendered.                    |
| `IDP_Country__mdt`                                 | CMDT           | One ISO country: dial code and decimal separator. DeveloperName is the country code.                        |
| `IDP_Language__mdt`                                | CMDT           | One ISO language: month names and decimal separator. DeveloperName is the language code.                    |
| `IdpMappingEngine`                                 | Apex           | Orchestrator. `run(List<DocumentWork>, setName, mode, handler)` → `List<IdpResult.Result>`.                 |
| `IdpConfigLoader`                                  | Apex           | Loads and validates one set's config into DTOs; config problems degrade to findings, never throw.           |
| `IdpContextResolver`                               | Apex           | Bulk anchor resolution: one `ContentDocumentLink` query per run, grouped queries per object.                |
| `IdpRuleEvaluator`                                 | Apex           | Read → parse/grade → gate → stage or compare, per rule per record.                                          |
| `IdpDmlExecutor`                                   | Apex           | Accumulates every write of the run; one partial-success update, FLS-stripped, outcomes mapped per document. |
| `IdpJsonReader`                                    | Apex           | Dot-path JSON reads, confidence-envelope aware (`{"value": …, "confidence": 0.93}`).                        |
| `IdpFilterBinder`                                  | Apex           | Binds `{json:…}` / `{row:…}` tokens in filters and key templates — values are bound, never concatenated.    |
| `IdpSchemaCache`                                   | Apex           | All describe access, cached; lookup discovery between objects. No `Schema.getGlobalDescribe()`.             |
| `IValueType` / `IdpValueTypes` / `IdpTypeRegistry` | Apex           | The value type contract, the eight built-ins, and resolution (built-in by Kind, custom by class name).      |
| `IdpLocaleData`                                    | Apex           | Dial codes, decimal separators and month names, read from the two tables above and cached per transaction.  |
| `IdpMappingInvocable`                              | Apex           | `Apply IDP Mapping Set` action for Flows — genuinely bulk: 50 interviews share one engine run.              |
| `IdpMappingController`                             | Apex           | `apply` / `preview` / `previewValue` for LWCs.                                                              |
| `IdpConfiguratorController`                        | Apex           | List, read, validate and save mapping set Definitions for the configurator.                                 |
| `IdpBatchProcessor`                                | Apex           | Batchable over records holding stored JSON (`JSON_Source_Field__c`).                                        |
| `IIdpFindingHandler`                               | Apex interface | Custom reaction to a run's findings; `IdpComplianceTaskHandler` is the bundled sample.                      |
| `IdpLimitsGuard`                                   | Apex           | Defers documents cleanly when governor headroom runs out.                                                   |
| `fileJsonReviewMappingDemo`                        | LWC            | Example host wiring `fileJsonReview` to the engine, with the Preview step.                                  |
| `idpConfigurator`                                  | LWC            | Form editor for each document type's sections and rules, with a raw-JSON tab. Saving deploys metadata.      |

Sections and rules are **JSON inside the set**, in `Definition__c`, rather
than records of their own. A long text area is charged a flat 255 characters
against the org's custom metadata allocation however much it holds, where the
same content as records cost roughly 22,000 characters per document type — and
that allocation is shared across every business unit in the org.

The trade is that object and field names are no longer `EntityDefinition` and
`FieldDefinition` relationships, so a typo can be saved. `IdpConfigLoader`
checks every name against the real schema when it loads and reports what it
cannot find, so a typo surfaces on the configurator's Check button or on the
first run rather than never. See
[**IDP_CONFIGURATION.md**](IDP_CONFIGURATION.md) for the format and every key.

## Configuring a mapping set

### `IDP_Mapping_Set__mdt` — the use case

| Field                       | Meaning                                                                                                      |
| --------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `Default_Mode__c`           | `Extraction` or `Compliance` when the caller passes no mode.                                                 |
| `JSON_Source_Field__c`      | `Object.Field` of the long-text field holding raw JSON for batch runs, e.g. `Document__c.Extracted_JSON__c`. |
| `Processed_Marker_Field__c` | Datetime field on the same object; makes the batch idempotent (see Batch below).                             |
| `Finding_Handler__c`        | Default `IIdpFindingHandler` class; a caller-supplied name overrides it.                                     |
| `Definition__c`             | The sections and rules, as JSON. See [IDP_CONFIGURATION.md](IDP_CONFIGURATION.md).                           |
| `Active__c`                 | Untick to disable the whole set.                                                                             |

The engine is called with the set's **DeveloperName**.

### Sections and rules — the set's `Definition__c`

Every rule belongs to a section (the v1 standalone-rule shape is gone — a
single record is just a Fixed section), and both live as JSON on the set:

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
                    "jsonPath": "applicant.email",
                    "targetField": "SuppliedEmail",
                    "overwritePolicy": "Always"
                }
            ]
        }
    ]
}
```

A section carries `name`, `label`, `sectionType` (`Fixed` or `Repeating`),
`targetObject`, `recordFilter`, `parentSection`, `active`, and for repeating
sections `rowPath`, `matchField` and `matchValue`. A rule carries `name`,
`label`, `jsonPath`, `targetField`, `valueTypeName`, `mode`,
`overwritePolicy`, `minGrade`, `minConfidence`, `required`, `anchorFilter`
and `active`.

**[IDP_CONFIGURATION.md](IDP_CONFIGURATION.md) is the manual** — what each key
means, what is required, worked examples, and what happens when a value is
wrong. Admins rarely see this JSON: the **IDP Configuration** page (App
Launcher, or the `idpConfigurator` LWC on any page) edits it as a form with
object and field pickers, and keeps the raw text on an Advanced tab. Either
way a draft is validated through `IdpConfigLoader` before it can be saved.

Unknown keys are screened before the typed parse, so a misspelled `jsonPaths`
stops the document type from loading — naming the key and the rule — instead
of silently mapping nothing. That screening is deliberate: `JSON.deserialize`
on its own ignores a key it does not recognize, which is the worst available
outcome for hand-edited configuration.

## Value types

A value type answers four questions about one semantic kind of value:

```apex
public interface IValueType {
    IdpValueTypes.ParseResult parse(Object raw, IdpValueTypes.Config cfg); // document → typed value + Grade
    Object canonical(Object value, IdpValueTypes.Config cfg); // EITHER side → comparable form
    IdpResult.CompareOutcome compare(
        Object extracted,
        Object stored,
        IdpValueTypes.Config cfg
    ); // MATCH | NEAR | MISMATCH
    String render(Object canonicalValue, IdpValueTypes.Config cfg); // canonical → stored/displayed text
}
```

### Grades — nothing is guessed silently

Every parse carries a grade the engine acts on:

| Grade       | Meaning                                           | Default behaviour                                      |
| ----------- | ------------------------------------------------- | ------------------------------------------------------ |
| `Exact`     | Deterministic reading.                            | Writes.                                                |
| `Inferred`  | A documented heuristic decided (note says which). | Writes, unless the rule demands `minGrade` of `Exact`. |
| `Ambiguous` | More than one legitimate reading (`03/04/2024`).  | **Never writes** — reported with every interpretation. |
| `Failed`    | No reading at all.                                | Error finding.                                         |

This is the successor to v1's silent regex-stripping, which read
`ZAR 100,00` as `10000`. v2 parses that as exactly `100` — and where a value
genuinely cannot be decided, it says so instead of picking.

### Built-in kinds (`Kind__c`)

| Kind       | Behaviour                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Config it reads                                                                               |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `Text`     | Trimmed; compares whitespace-collapsed and case-insensitively.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | —                                                                                             |
| `Number`   | Money and plain numbers: both separator conventions, `(…)`, trailing `-` and `CR`/`DR` negatives, "in thousands" scaling. Both separators present → last one is the decimal (Exact). A single separator is Exact with a `Locale__c`, graded heuristic without. **Currency is captured, not stripped**: an ISO code or unambiguous symbol next to the amount becomes the parse's `currencyCode`; a stated currency that disagrees with `Currency__c` fails the parse; ambiguous symbols (`$`, `¥`, `kr`) are never guessed — declare `Currency__c` instead. In a multi-currency org a value denominated differently from the record's `CurrencyIsoCode` is refused (`CURRENCY_MISMATCH`) rather than written or "confirmed". | `Locale__c`, `Currency__c`, `Scale_Factor__c`, `Compare_Tolerance__c`                         |
| `Date`     | Ordered `Formats__c` pattern list (`dd/MM/yyyy\|d MMMM yyyy\|yyyy-MM-dd`); month names are read in `Locale__c`'s language (below); text in `'single quotes'` is literal, so `d 'de' MMMM 'de' yyyy` reads a Romance long date; components are range-checked (31/02 fails); two patterns reading differently → Ambiguous.                                                                                                                                                                                                                                                                                                                                                                                                    | `Formats__c`, `Locale__c`, `Pivot_Year__c`, `Output_Format__c`, `Compare_Tolerance__c` (days) |
| `Datetime` | ISO 8601. An explicit offset is Exact; a naive timestamp is read in `Timezone__c` (Exact) or as GMT (Inferred, flagged).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | `Timezone__c`, `Compare_Tolerance__c` (minutes)                                               |
| `Boolean`  | true/yes/y/1, false/no/n/0.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | —                                                                                             |
| `Phone`    | Canonical E.164: `+27 82 123 4567`, `0027…` and — with `Region__c = ZA` — `082 123 4567` all become `+27821234567`. Renders `e164` (default), `national` or `digits`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | `Region__c`, `Output_Format__c`                                                               |
| `ValueMap` | Admin dictionary: the value type's `Value_Map_Entries__c` JSON translates document wording into stored values ("Pty Ltd" → `Private Company`), matched Exact, Normalized or Regex. Unmapped input fails loudly.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | its map entries                                                                               |
| `Regex`    | Extracts the first capturing group of the pattern in `Formats__c` (used unsplit, so `\|` alternations work).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | `Formats__c`                                                                                  |
| `Custom`   | Your Apex class implementing `IValueType`, named in `Handler_Class__c`, resolved with `Type.forName`. `Custom_Options__c` JSON is passed through.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `Handler_Class__c`, `Custom_Options__c`                                                       |

Declare the document's formatting **once** on a value type record and point
rules at it — not per rule, and not in code.

### Locale reference data — `IDP_Country__mdt` and `IDP_Language__mdt`

Two org-wide reference tables, not per-mapping-set config — which is why they
are documented here, beside the `Region__c` and `Locale__c` fields that reach
them, rather than under _Configuring a mapping set_. Onboarding a market is a
record, not a release.

**Symptoms that send you here:** amounts parsing `Inferred` with a note asking
for a Locale; long-form dates failing in a non-English document; phone numbers
staying as digits instead of becoming `+…`; a config issue reading _"has
unknown Region"_ or _"has unrecognized Locale"_.

#### `IDP_Country__mdt` — one country

DeveloperName **is** the ISO 3166-1 alpha-2 code, uppercase: `ZA`, `DE`, `PL`.
Nothing else looks it up, so a typo here is a country that silently does not
exist.

| Field                  | Meaning                                                                                                                                               |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MasterLabel`          | The country's name, for humans. Never read by the engine.                                                                                             |
| `Dial_Code__c`         | E.164 calling code, digits only, **no `+`** — `27`, `49`, `48`. Reached by a Phone value type's `Region__c`. Blank leaves national numbers as digits. |
| `Decimal_Separator__c` | `,` or `.` — what this country prints between units and cents. Beats the language (below). Blank falls through to the language.                       |

#### `IDP_Language__mdt` — one language

DeveloperName **is** the ISO 639-1 code, lowercase: `en`, `pt`, `pl`.

| Field                  | Meaning                                                                                                                                                                                        |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MasterLabel`          | The language's name, for humans. Never read by the engine.                                                                                                                                     |
| `Decimal_Separator__c` | `,` or `.` — used when `Locale__c` names no country, or names one with no separator of its own.                                                                                                |
| `Month_Names__c`       | Twelve `\|`-separated months, **January first**. Each may list `,`-separated spellings, the first canonical. Blank means this language cannot read `MMM`/`MMMM`, and it falls back to English. |

#### How a value type reaches them

| Value type field | Resolves to                                                                                                          |
| ---------------- | -------------------------------------------------------------------------------------------------------------------- |
| `Region__c`      | `IDP_Country__mdt.Dial_Code__c`. One country code, e.g. `ZA`.                                                        |
| `Locale__c`      | A `language[-COUNTRY]` tag, e.g. `pl`, `pl-PL`, `de-CH`. Supplies the decimal separator and the month-name language. |

**The country subtag wins** for the separator: `de-CH` reads Swiss dot decimals
while `de-DE` reads German comma decimals, and `en-ZA` reads South Africa's
comma over English's dot. Month names always come from the **language** subtag.
Nothing seeded → the graded heuristic, unchanged.

#### Writing `Month_Names__c`

Matching is **case- and accent-blind**, on the whole name or on a prefix of
three letters or more that **only one month answers to**.

```
Januar|Februar|März,Maerz,Mrz|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember
```

- Accents fold, so `März` already matches `MARZ` and `marz` — **no `Marz` alias
  needed**. `Maerz` _is_ needed: it is a different spelling, not an accent.
- Three-letter abbreviations that are prefixes come free: `Mar`, `Dez`, `Jun`.
  Only list an abbreviation that is **not** a prefix of the name — German `Mrz`.
- List inflected forms that are not prefixes either — Polish genitive
  `styczeń,stycznia`, Czech `leden,ledna`. Documents print those, not the
  nominative.
- A prefix two months share is **reported, not guessed**: Portuguese `mar` is
  março (maio is `mai`), but French `jui` matches juin and juillet, so it yields
  no reading and the Date type fails the parse.
- Exactly twelve entries, or the whole row is ignored and the loader says so.

#### Onboarding a new market — worked example, Poland

1. **Add the country.** Setup → Custom Metadata Types → IDP Country → Manage
   Records → New. Label `Poland`, Name `PL`, `Dial_Code__c` = `48`,
   `Decimal_Separator__c` = `,`.
2. **Add the language**, if it is not already seeded. IDP Language → New. Label
   `Polish`, Name `pl`, `Decimal_Separator__c` = `,`, and `Month_Names__c`:
    ```
    styczeń,stycznia|luty,lutego|marzec,marca|kwiecień,kwietnia|maj,maja|czerwiec,czerwca|lipiec,lipca|sierpień,sierpnia|wrzesień,września|październik,października|listopad,listopada|grudzień,grudnia
    ```
3. **Point a value type at it.** On your Date value type set `Locale__c` = `pl`
   and add a pattern such as `d MMMM yyyy`; on your Number value type set
   `Locale__c` = `pl-PL`; on your Phone value type set `Region__c` = `PL`.
4. **Test it without deploying anything** — `previewValue` (next section) on
   `15 września 2024` should return `2024-09-15`, grade `Exact`.

To keep the change in source control instead, add the line to the table in
[`seed-locale-metadata.mjs`](force-app/idp/scripts/seed-locale-metadata.mjs) and
regenerate — the records are generated output, so hand-editing them is lost on
the next run:

```bash
node force-app/idp/scripts/seed-locale-metadata.mjs
```

⚠️ The two paths are not independent. A record you create in Setup is
**overwritten by the next deploy** of `force-app/idp/main` if the script's table
also carries that code — and all 91 seeded countries do. Use Setup to try a
change, the script to keep one.

#### Two deliberate limits

Deliberately **not** Java locale data: `Datetime.parse` resolves against the
running user's locale, so the same document would read differently depending on
who ran the job. A value type names the locale of the _document_, and that is
the only locale consulted.

Rendering is **not** localised — `Output_Format__c` produces English month names
in every locale, because it writes into org-side fields, not back into the
document. A German value type reads `März` and writes `March`.

Seeded with 91 countries and 22 languages. The loader reports an unseeded
`Region__c` or `Locale__c`, and a Date type reading month names in a language
that declares none, as config issues at load time rather than letting them
surface as a quietly degraded parse.

### Testing a value type without deploying anything

`IdpMappingController.previewValue(valueTypeName, rawText)` parses sample text
through a value type and returns the canonical value, the grade, the note and
the rendered output — the difference between config being _configurable_ and
being _fiddly_.

### Confidence envelopes

An IDP service that reports per-field OCR confidence can wrap any node as
`{"value": "Jane", "confidence": 0.93}`. The envelope is transparent to JSON
paths; the innermost confidence travels with the value, and a rule's
`minConfidence` turns it into a gate — below the threshold the value is
reported (`LOW_CONFIDENCE`) instead of written.

## Compliance: three-state, both sides canonicalized

v1 compared the _parsed document value_ against the _raw stored value_, so a
stored `0821234567` mismatched a document's `+27 82 123 4567` forever. v2 runs
**both sides** through the value type's `canonical()` before comparing, and
the verdict has three states:

- **Match** — same value.
- **Near** — within the type's `Compare_Tolerance__c` (a cent, two days, the
  same national number without provable country code). Reported as a
  `VALUE_NEAR` finding for a human to glance at, but does **not** clear
  `compliant`.
- **Mismatch** — a `VALUE_MISMATCH` finding; clears `Result.compliant`.

A blank stored field cannot confirm the document, so it is a mismatch. A JSON
path missing from the document is skipped (unless the rule is `required`).
Mismatches are data, not failures: `Result.success` stays true.

### Finding handlers

When a run produces mismatches and a handler is configured — on the set's
`Finding_Handler__c` or passed by the caller (which wins) — the engine
instantiates it via `Type.forName`:

```apex
public interface IIdpFindingHandler {
    void handle(IdpResult.RunReport report);
    // report: mappingSetName, mode, every document's full Result
}
```

The bundled `IdpComplianceTaskHandler` raises one review Task per
non-compliant document. Handlers run inside the same transaction; one that
throws becomes a `HANDLER_FAILED` finding without rolling back extraction
updates from that run. The findings come back on the `Result` regardless, so
the hosting Flow or LWC can react whether or not a handler is configured.

## Sections: fixed and repeating regions

A **Fixed** section writes one record. A **Repeating** section iterates the
array at `rowPath` and reads each rule's `jsonPath` relative to the
current row, so the rule count stays constant no matter how many rows the
document has.

### Match values

`matchValue` builds the key each row is looked up by. Tokens:
`{json:path}` reads from the document root, `{row:path}` from the current
row, `{row:index}` is the 0-based position and `{row:number}` the 1-based
one. Whole numbers render without a decimal point, so line 2 is `2`, never
`2.0`.

`matchField` does **not** have to be an External Id — rows are matched
with a SOQL query, so any queryable field works.

### What repeating sections do and do not do

Rows are **matched and updated** by default. A document row whose key
finds no record is reported in `Result.unmatchedRowKeys` (and as a
`ROW_UNMATCHED` info finding) — data, not an error. Two document rows
rendering the same key: the second is skipped and reported rather than
silently overwriting the first.

Setting `"unmatchedRows": "Create"` on the section opts it into creating
the missing rows instead: the match key, the parent lookup and the
section's rule values land in the run's single partial-success insert, and
each success is a `ROW_CREATED` finding (`rowsCreated` and
`createdRecordIds` on the Result). Extraction only — Preview reports what
would be created (`PlannedChange.isNew`) and Compliance never creates. The
equivalent for a fixed section whose target is unreachable is
`"whenNoAnchor": "Create"`, which builds the missing anchor linked to the
first resolved record it looks up to (`ANCHOR_CREATED`).

Where a lookup from the row object to a resolved record exists, rows are
constrained to it, so a key that is only unique within one account cannot
reach another account's rows; `parentSection` picks that record
explicitly instead of letting the schema decide.

Cost does not grow with rows **or documents**: one query per repeating
section per run covers every row of every document (keys are matched
`IN :keys`, constrained `lookup IN :parentIds`), and all updates ride the
run's single DML. Ten 200-line statements cost the same as one 2-line
invoice.

## Reachable objects

`targetObject` accepts any object, standard or custom. Nothing is
hard-coded: `IdpContextResolver` works out the path from each document to
each target at run time, for all documents at once —

1. **Roots.** Every record the file is linked to through
   `ContentDocumentLink` (one query covers the whole run; system link types
   are skipped) — or, for a document seeded from a record instead of a file,
   that record itself. The `Document__c` hub's own lookups are followed so
   its parents serve as stepping stones.
2. **Parent hops.** An anchored record holds a lookup to the target
   (`Document__c.Case__c` → Case, `Case.AccountId` → Account).
3. **Child hops.** The target holds a lookup back to an anchored record
   (`Estate_Case__c.Case__c = :caseId`); the newest child wins.

Passes repeat (up to three) until every target resolves or no progress is
made; each pass groups its queries per object across all documents. Lookups
are discovered from the schema (a field named `<Object>__c` / `<Object>Id`
is preferred; ambiguity without the conventional name resolves nothing), so
the classes deploy to any org and an unreachable target is a per-section
finding, not a failed run.

### Anchor filters

`anchorFilter` / `recordFilter` narrow which record anchors:

```
Status__c = 'Active' AND Policy_Number__c = {json:policy.number}
```

Constants are metadata written by whoever deploys the set; `{json:path}`
tokens become **bind variables** holding document values, so document content
cannot inject SOQL. A filter that binds document values naturally differs per
document — those objects drop to per-document queries; constant filters stay
grouped.

## Results and findings

One `IdpResult.Result` per document. Instead of parallel string lists, every
noteworthy event is a **Finding** with a machine-readable code, a severity
and a human message, plus whatever context applies (object, record, field,
JSON path, section, row, raw/extracted/stored values, grade, confidence):

| Code                                                                      | Severity | Meaning                                                                |
| ------------------------------------------------------------------------- | -------- | ---------------------------------------------------------------------- |
| `CONFIG_ISSUE`                                                            | Warn/Err | A rule or section was disabled by validation; the set ran without it.  |
| `JSON_INVALID`, `INVALID_INPUT`, `INVALID_MODE`                           | Error    | The document or call could not be processed.                           |
| `UNREACHABLE_TARGET`, `UNKNOWN_FIELD`                                     | Error    | Schema problems, reported per section / rule.                          |
| `REQUIRED_MISSING`                                                        | Error    | A `required` path is absent from the document.                         |
| `PARSE_FAILED` / `PARSE_AMBIGUOUS` / `BELOW_MIN_GRADE` / `LOW_CONFIDENCE` | Err/Warn | The value could not be used; the finding says exactly why.             |
| `PICKLIST_INVALID`                                                        | Error    | Not an active value of a restricted picklist.                          |
| `CURRENCY_MISMATCH`                                                       | Error    | The document's currency disagrees with the record's `CurrencyIsoCode`. |
| `VALUE_MISMATCH` / `VALUE_NEAR`                                           | Warning  | Compliance verdicts.                                                   |
| `ROW_UNMATCHED` / `ROW_DUPLICATE_KEY` / `ROW_LOOKUP_FAILED`               | Info/Err | Repeating-section row outcomes.                                        |
| `FLS_BLOCKED`, `DML_FAILED`, `HANDLER_FAILED`                             | Error    | Write-side problems, attributed to the documents involved.             |
| `DOC_DEFERRED`                                                            | Error    | The limits guard postponed this document — rerun it.                   |

Convenience on the Result: `success` (no Error findings), `compliant` (no
mismatches), `deferred`, counters (`fieldsApplied`, `fieldsCompared`,
`rowsMatched`, `rowsUpdated`), `updatedRecordIds`, `unmatchedRowKeys`, and
`plannedChanges` (each `{objectName, recordId, fieldName, oldValue, newValue,
grade}` — populated in Preview and on real extraction runs alike).

## Error handling and resilience

The engine is built around partial success at every level: a bad rule is
disabled by the loader while the rest of the set runs; a bad value produces a
finding while the other fields carry on; a bad document never fails its
neighbours in the run; DML uses `Database.update(records, false)`; and when
governor headroom runs short, `IdpLimitsGuard` defers whole documents
(`deferred = true`) instead of blowing the transaction.

Security: anchors and row lookups are queried in `USER_MODE`, and updates
pass through `Security.stripInaccessible(AccessType.UPDATABLE, …)`; stripped
fields are reported as `FLS_BLOCKED` findings on the documents that staged
them.

## Performance model

For a run of N documents against one mapping set:

- 1 `ContentDocumentLink` query (whole run),
- ~1 query per anchored object per resolver pass (grouped across documents),
- 1 query per repeating section group (all keys, all documents),
- ≤ 1 update DML for everything staged.

Query count is independent of rule count and row count. Custom metadata SOQL
is limits-free, config/describes/type handlers are cached per transaction,
and `Schema.getGlobalDescribe()` is never called. `IdpMappingEngineTest`
asserts the budget for a 3-document run.

## Batch: reprocessing stored documents

Persist the raw JSON on the record the document belongs to (the mapping
set's `JSON_Source_Field__c`, e.g. `Document__c.Extracted_JSON__c`), and:

```apex
Database.executeBatch(new IdpBatchProcessor('Consolidated_Statement'), 10);
```

`start()` iterates that object's records (an optional scope SOQL overrides
it); each `execute()` chunk seeds the engine from the records themselves —
no files involved — and is one bulk engine run. Modes and handlers work
exactly as in interactive runs; `finish()` logs the aggregate.

**Idempotency.** Name a Datetime `Processed_Marker_Field__c` on the mapping
set and the batch only picks up records where it is blank, stamping each
once processed (successfully or with errors — both are attempts whose
findings went to the handler). Rerunning then never redoes finished work.
Documents the limits guard deferred stay unstamped, and `finish()` chains a
retry pass for exactly those records. To force a full rerun after a rule
change, pass `reprocessAll = true` (the fifth constructor argument) or
clear the marker on the records you want redone.

## Usage from a Screen Flow

1. Add a screen element hosting **fileJsonReview**, giving it the
   `contentDocumentId` and the `jsonInput` from your OCR/IDP response.
2. Follow it with the **Apply IDP Mapping Set** action:
    - _Content Document Id_ → the same `contentDocumentId` (or _Record Id_ to
      seed from a record instead)
    - _JSON String_ → the screen component's `jsonOutput`
    - _Mapping Set Name_ → e.g. `Estate_Intake`
    - _Mode_ → blank inherits the set's default; `Extraction`, `Compliance` or
      `Preview`
    - _Finding Handler Class_ → optional override of the set's default
3. Branch on `success` and `compliant`; show `findings` (or just the
   Error-severity ones) and, for repeating sections, `rowsMatched` /
   `unmatchedRowKeys` on a result screen.

The action is bulk-safe: 50 interviews reaching it together share one engine
run.

## Usage from a parent LWC

`fileJsonReviewMappingDemo` is the reference implementation. It hosts
`c-file-json-review` and, on submit, previews first:

```js
import apply from '@salesforce/apex/IdpMappingController.apply';
import preview from '@salesforce/apex/IdpMappingController.preview';

// 1. preview() → show result.plannedChanges (old → new, per-field grade)
// 2. user confirms → apply() with the same JSON
// 3. render result.findings / result.plannedChanges; toast on success
```

Point its _Content Document Id_ at a file linked to a Case (or to a
`Document__c` that looks up to one), press **Preview changes**, then
**Confirm & Save**. Switch _Mode_ to `Compliance` and the same button becomes
**Check compliance**: nothing is written, and the Match/Near/Mismatch table
appears under the review pane.

## Extending

- **A new use case** needs no code: a new `IDP_Mapping_Set__mdt` with
  sections and rules.
- **A new document format** usually needs no new config either — add the
  format to the relevant value type's `Formats__c` list or its value map.
- **A new value semantics** means one `IDP_Value_Type__mdt` record — and only
  for genuinely new _behaviour_ an Apex class implementing `IValueType`
  (Kind = Custom). The engine does not change.
- **A new finding reaction** means implementing `IIdpFindingHandler`, using
  `IdpComplianceTaskHandler` or the loan-offer example's handler as a
  template.
- **A new traversal pattern** (not a new object — those just work) is the
  only thing that calls for changes in `IdpContextResolver`.

## Worked examples

Four runnable examples live in
[`force-app/idp/examples/`](force-app/idp/examples/README.md), each with its
own mapping set, value types, custom fields, permission set, seed data,
sample PDF and deployment commands:

| Example                                                                               | Mode       | Adds                                                                       |
| ------------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------------- |
| [Business Account Opening](force-app/idp/examples/business-account-opening/README.md) | Extraction | Fixed sections, `Only if blank`, date/money/phone value types, a value map |
| [Consolidated Statement](force-app/idp/examples/consolidated-statement/README.md)     | Extraction | A repeating detail band, `parentSection`, `recordFilter`, **batch**        |
| [Loan Offer Compliance](force-app/idp/examples/loan-offer-compliance/README.md)       | Compliance | Set-level defaults, Near verdicts, a custom `IIdpFindingHandler`           |
| [Letters of Executorship](force-app/idp/examples/letters-of-executorship/README.md)   | Extraction | A custom object via child hop, Regex value type, `required`                |

They sit outside the package directory, so they only reach an org when you
deploy one by name.

---

_Related docs: [README.md](README.md) (documentation index),
[DOC_PREVIEWER.md](DOC_PREVIEWER.md) (the `fileJsonReview` previewer),
[JSON_FORM.md](JSON_FORM.md) (the `jsonForm` child component)._
