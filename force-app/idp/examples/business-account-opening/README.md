# Example 1 — Business Account Opening (Extraction, fixed sections)

A prospective business customer returns a completed account opening form. The
branch scans it, the OCR/IDP service turns it into JSON, an agent reviews that
JSON in `fileJsonReview`, and pressing **Save** writes the confirmed values
onto the customer's Account and onto the Case tracking the application.

This is the simplest shape the mapping engine takes: **Data Extraction** mode,
two **Fixed** sections, no repeating band. Nothing here is code — the whole
behaviour is thirteen `JSON_Field_Mapping__mdt` records and two
`JSON_Mapping_Section__mdt` records.

## What it demonstrates

| Feature                         | Where to look                                                                                        |
| ------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Fixed sections                  | Two sections declare the target object once; the thirteen rules never repeat `Target_Object__c`.     |
| Multi-object writes in one call | `Customer` writes to Account, `Application` writes to Case — reached from one file.                  |
| Record reachability             | The file is linked to the **Case**; the Account is found by following `Case.AccountId`.              |
| `Only if blank`                 | The blank `Account.Phone` gets filled; the pre-populated `Case.Description` is deliberately left be. |
| Date transforms                 | `09/03/2018` is read as 9 March 2018 via `Transform__c = dd/MM/yyyy`.                                |
| Numeric cleanup                 | `"R 8 420 000.00"` lands in a Currency field as `8420000.00`.                                        |
| Restricted picklists            | `Private Company` and `Business Cheque Account` are validated against the picklist before the write. |

## The document and the JSON

- [`documents/business-account-opening-application.pdf`](documents/business-account-opening-application.pdf)
  — what the reviewer sees on the left of `fileJsonReview`.
- [`sample/extracted.json`](sample/extracted.json) — what the OCR/IDP service
  would have returned for it, and what you paste into the component's
  **Source JSON**.

```json
{
  "application": { "reference": "AO-2026-118842", "branchCode": "0421", ... },
  "business":    { "registeredName": "Blue Harbour Trading", "annualTurnover": "R 8 420 000.00", ... },
  "signatory":   { "fullName": "Thandi Mokoena", ... }
}
```

Note that the JSON is grouped by _what the document says_ (application,
business, signatory) while the sections are grouped by _where it goes_ (Case,
Account). The two do not have to line up: a Fixed section only decides the
target object, and each rule's `JSON_Path__c` is read from the document root.
That is why the signatory's name and email sit in the `Application` section —
they belong on the Case.

## The configuration

Mapping set: **`Account_Opening_Intake`**

### Sections ([`customMetadata/`](customMetadata))

| Section       | Type  | Target object |
| ------------- | ----- | ------------- |
| `Customer`    | Fixed | `Account`     |
| `Application` | Fixed | `Case`        |

### Rules

| Section       | `JSON_Path__c`                | Target field                      | Policy        | Transform    |
| ------------- | ----------------------------- | --------------------------------- | ------------- | ------------ |
| `Customer`    | `business.registrationNumber` | `Account.Registration_Number__c`  | Always        |              |
| `Customer`    | `business.taxReference`       | `Account.Tax_Reference_Number__c` | Always        |              |
| `Customer`    | `business.dateIncorporated`   | `Account.Date_Incorporated__c`    | Always        | `dd/MM/yyyy` |
| `Customer`    | `business.entityType`         | `Account.Entity_Type__c`          | Always        |              |
| `Customer`    | `business.annualTurnover`     | `Account.Annual_Turnover__c`      | Always        |              |
| `Customer`    | `business.phone`              | `Account.Phone`                   | Only if blank |              |
| `Application` | `application.reference`       | `Case.Application_Reference__c`   | Always        |              |
| `Application` | `application.branchCode`      | `Case.Branch_Code__c`             | Always        |              |
| `Application` | `application.product`         | `Case.Product_Applied_For__c`     | Always        |              |
| `Application` | `application.signedDate`      | `Case.Application_Signed_Date__c` | Always        |              |
| `Application` | `application.notes`           | `Case.Description`                | Only if blank |              |
| `Application` | `signatory.fullName`          | `Case.SuppliedName`               | Always        |              |
| `Application` | `signatory.email`             | `Case.SuppliedEmail`              | Always        |              |

### Custom fields ([`objects/`](objects))

Nine custom fields on two standard objects — no new objects, so the example
installs anywhere:

- **Account** — `Registration_Number__c`, `Tax_Reference_Number__c`,
  `Date_Incorporated__c`, `Entity_Type__c` (restricted picklist),
  `Annual_Turnover__c` (Currency)
- **Case** — `Application_Reference__c`, `Branch_Code__c`,
  `Product_Applied_For__c` (restricted picklist), `Application_Signed_Date__c`

Permission set **`IDP_Example_Account_Opening`** grants read/edit on all nine.
Without it the engine reports `No update access to …` instead of writing,
because it applies `stripInaccessible` before every save.

## Deploy it

The engine itself has to be in the org first — deploy it once, then the
example. `<alias>` is your org alias throughout.

```bash
sf project deploy start --source-dir force-app/idp/main --target-org <alias>
```

```bash
sf project deploy start --source-dir force-app/idp/examples/business-account-opening --target-org <alias>
```

```bash
sf org assign permset --name IDP_Example_Account_Opening --target-org <alias>
```

## Load the data

One Account (with **no** phone number and none of the KYC fields filled) and
one Case looking up to it, carrying a Description that must survive the run:

```bash
sf data import tree --plan force-app/idp/examples/business-account-opening/data/plan.json --target-org <alias>
```

Find the Case the file has to hang off:

```bash
sf data query --query "SELECT Id, CaseNumber FROM Case WHERE Subject = 'Business account opening - Blue Harbour Trading'" --target-org <alias>
```

Upload the scanned application to it, substituting the Id you just got:

```bash
sf data create file --file force-app/idp/examples/business-account-opening/documents/business-account-opening-application.pdf --title "Business Account Opening Application" --parent-id <caseId> --target-org <alias>
```

Finally print the `ContentDocumentId` the component needs (this also repairs
the link if the upload went somewhere else):

```bash
sf apex run --file force-app/idp/examples/business-account-opening/scripts/setup.apex --target-org <alias>
```

## Run it

Drop **File JSON Review + Field Mapping Demo** (`fileJsonReviewMappingDemo`)
on any App or Home page and set:

| Property            | Value                                   |
| ------------------- | --------------------------------------- |
| Content Document Id | the Id printed by `setup.apex`          |
| Source JSON         | the contents of `sample/extracted.json` |
| Mapping Set         | `Account_Opening_Intake`                |
| Mode                | `Extraction`                            |

Review the form on the right — correct anything the OCR got wrong, which is
the point of the component — and press **Save to Salesforce**. The toast
reports `12 field(s) applied to 2 record(s)`.

Twelve, not thirteen: `Case.Description` is skipped because it already holds
the branch note, and `Account.Phone` is written because it was blank. That
asymmetry is `Overwrite_Policy__c` doing its job.

The same thing works from a Screen Flow — host `fileJsonReview`, then call the
**Apply JSON Field Mappings** action with the same four values. See
[JSON_FIELD_MAPPING.md](../../../../JSON_FIELD_MAPPING.md#usage-from-a-screen-flow).

## Verify

```bash
sf data query --query "SELECT Name, Registration_Number__c, Tax_Reference_Number__c, Date_Incorporated__c, Entity_Type__c, Annual_Turnover__c, Phone FROM Account WHERE Name = 'Blue Harbour Trading'" --target-org <alias>
```

```bash
sf data query --query "SELECT CaseNumber, Application_Reference__c, Branch_Code__c, Product_Applied_For__c, Application_Signed_Date__c, SuppliedName, Description FROM Case WHERE Subject = 'Business account opening - Blue Harbour Trading'" --target-org <alias>
```

Expect `Date_Incorporated__c` = `2018-03-09` (not 3 September),
`Annual_Turnover__c` = `8420000.00`, `Phone` = `+27 21 555 0142`, and a
`Description` still describing the FICA pack.

## Things worth trying

- Change `business.entityType` in the JSON to `Close Corporation` and save
  again. The rule fails with _"Close Corporation" is not an active value of
  picklist Entity_Type\_\_c_ in `result.errors`, while the other twelve fields
  still apply — the engine's partial-success behaviour.
- Change `business.dateIncorporated` to `2018-03-09` without changing
  `Transform__c`. It fails to parse, because the rule promised `dd/MM/yyyy`.
- Delete `business.taxReference` from the JSON entirely. No error: a path that
  is simply absent is skipped, since a document that does not mention a field
  says nothing about it.

## Clean up

```bash
sf data delete record --sobject Case --where "Subject='Business account opening - Blue Harbour Trading'" --target-org <alias>
```

```bash
sf data delete record --sobject Account --where "Name='Blue Harbour Trading'" --target-org <alias>
```

---

_Back to the [examples index](../README.md) · engine reference:
[JSON_FIELD_MAPPING.md](../../../../JSON_FIELD_MAPPING.md)_
