# IDP Examples

Four self-contained demonstrations of [`fileJsonReview`](../../../DOC_PREVIEWER.md)
driving the [JSON field mapping engine](../../../JSON_FIELD_MAPPING.md) — three
set in a generic retail/commercial bank, one in a bank's deceased estates
department.

Each one ships everything it needs: its own mapping set, its own custom
fields, its own seed data, its own sample document and a README you can follow
end to end. Nothing is shared between them, so you can install one, all four,
or none.

## Index

| #   | Example                                                            | Mode       | Sections              | The idea                                                                                                           |
| --- | ------------------------------------------------------------------ | ---------- | --------------------- | ------------------------------------------------------------------------------------------------------------------ |
| 1   | **[Business Account Opening](business-account-opening/README.md)** | Extraction | 2 × Fixed             | A scanned account opening form fills in the customer's KYC details and the application Case.                       |
| 2   | **[Consolidated Statement](consolidated-statement/README.md)**     | Extraction | 1 Fixed + 1 Repeating | A month-end statement refreshes every product the customer holds — a detail band of any length, six rules.         |
| 3   | **[Loan Offer Compliance](loan-offer-compliance/README.md)**       | Compliance | 2 × Fixed             | A signed offer letter is checked against the approved terms; the differences go to a custom mismatch handler.      |
| 4   | **[Letters of Executorship](letters-of-executorship/README.md)**   | Extraction | 2 × Fixed             | A Master's appointment letter fills in the Estate Case — a **custom object reached by a child hop** from the Case. |

### What each one adds

| Engine feature                                       | 1   | 2   | 3   | 4   |
| ---------------------------------------------------- | --- | --- | --- | --- |
| Fixed sections                                       | ✅  | ✅  | ✅  | ✅  |
| Repeating sections (`Row_Path__c`, `Match_Value__c`) |     | ✅  |     |     |
| `Parent_Section__c` row scoping                      |     | ✅  |     |     |
| `Record_Filter__c` / `unmatchedRowKeys`              |     | ✅  |     |     |
| `Overwrite_Policy__c = Only if blank`                | ✅  |     |     |     |
| Date `Transform__c`                                  | ✅  | ✅  | ✅  | ✅  |
| Restricted picklist coercion                         | ✅  | ✅  |     | ✅  |
| Compliance comparison rules                          |     |     | ✅  |     |
| Per-rule `Mode__c` override                          |     |     | ✅  |     |
| `IComplianceMismatchHandler`                         |     |     | ✅  |     |
| Child-hop resolution to a custom object              |     |     |     | ✅  |
| Two sections sharing one target object               |     |     |     | ✅  |

If you are reading these in order, example 1 is the one to start with — it is
the whole engine minus the features the others add. Example 4 is the one to
read if your data does not live on the object the file is filed against.

## How an example is laid out

```
<example>/
  README.md          what it is, what it demonstrates, how to deploy and run it
  customMetadata/    the JSON_Field_Mapping__mdt and JSON_Mapping_Section__mdt records
  objects/           the custom fields it adds
  permissionsets/    field (and class) access, so the engine can actually write
  classes/           Apex, where the example needs it (example 3 only)
  data/              sf data tree plan and records
  documents/         the sample PDF the reviewer sees
  sample/            the JSON the OCR/IDP service would have returned for it
  scripts/           setup.apex — links the file and prints the ContentDocumentId
```

Alongside the examples there is one shared folder:

```
bootstrap/           metadata an example expects the org to already have,
  estate-case/       for orgs that do not — deployed only on purpose
```

`bootstrap/` sits **outside** every example directory on purpose. `sf project
deploy start --source-dir` deploys a directory and everything beneath it, so a
prerequisite kept inside an example would ride along with that example's own
deploy. Example 4 uses `bootstrap/estate-case` for `Estate_Case__c` — an object
a real deceased-estates org already owns, and which deploying blindly would
overwrite.

Every example follows the same five steps, spelled out with full commands in
its own README:

1. **Deploy the engine** — `force-app/idp/main`, once per org.
2. **Deploy the example** — `force-app/idp/examples/<example>`.
3. **Assign the permission set.**
4. **Import the data**, upload the document, run `setup.apex`.
5. **Host the demo LWC** (or a Screen Flow) and press the button.

## These examples are not part of the package

`force-app/idp/examples` sits deliberately **outside** the package directory,
which stops at `force-app/idp/main`. A normal deploy therefore never carries
demo fields and demo records into a real org:

```bash
sf project deploy start --source-dir force-app/idp/main --target-org <alias>
```

An example only arrives when you name it:

```bash
sf project deploy start --source-dir force-app/idp/examples/consolidated-statement --target-org <alias>
```

> `.forceignore` would not work here — it is applied to explicit `--source-dir`
> deploys too, so an ignored example could never be deployed on purpose either.
> Living outside the package directory gives the opt-in behaviour without that
> trap.

Best installed in a **scratch org or sandbox**. Each example adds custom fields
(to Account, Case, Asset, and for example 4 `Estate_Case__c`) and inserts
records; neither is something to do casually in production.

## Regenerating the sample documents

The PDFs are generated from plain-text descriptions in
[`tools/generate-sample-pdfs.mjs`](tools/generate-sample-pdfs.mjs) so they stay
reviewable. After editing a document:

```bash
node force-app/idp/examples/tools/generate-sample-pdfs.mjs
```

Keep the text in step with the matching `sample/extracted.json` — the value of
these examples is that what the reviewer reads on the left of `fileJsonReview`
is what the engine is fed on the right.

---

_Engine reference: [JSON_FIELD_MAPPING.md](../../../JSON_FIELD_MAPPING.md) ·
previewer: [DOC_PREVIEWER.md](../../../DOC_PREVIEWER.md) ·
[repository index](../../../README.md)_
