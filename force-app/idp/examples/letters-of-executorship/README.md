# Example 4 — Letters of Executorship (Extraction, fixed sections, child hop)

The Deceased Estates department cannot touch a cent of an estate until the
Master of the High Court has appointed someone to administer it. That
appointment arrives as a **J238 Letters of Executorship**: one page naming the
estate, the executor, and the deceased. Until its details are captured, every
account in the estate stays frozen.

So the branch scans the Letters, the OCR/IDP service turns it into JSON, an
estates administrator reviews that JSON in `fileJsonReview`, and pressing
**Save** writes the nine confirmed values onto the **Estate Case** — the record
the whole estate hangs off.

This is **Data Extraction** mode with two **Fixed** sections and no repeating
band. Nothing here is code: the behaviour is one `IDP_Mapping_Set__mdt` whose
Definition declares two sections and nine rules, plus two value types.

> **The document is a specimen.** The PDF is a generated stand-in marked
> SPECIMEN top and bottom, with fictitious names and identity numbers. It is a
> test fixture for the mapping engine, not an issued legal instrument, and it
> is not a Department of Justice form.

## What it demonstrates

Two things none of examples 1–3 show:

| Feature                        | Where to look                                                                                                                                                    |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Child hop resolution**       | The file is linked to the **Case**. Nothing points from the Case to the Estate Case — the engine finds it by looking for the child whose `Case__c` is that Case. |
| **Writing to a custom object** | Every rule targets `Estate_Case__c`, proving the engine is not limited to the standard objects the other examples use.                                           |
| **Two sections, one object**   | `Appointment` and `Deceased` both target `Estate_Case__c`. Sections group the **document**; the object is the **destination**. They merge into a single update.  |
| Date value type                | `LX_Date_ZA` reads `14/02/2026`, `8 April 2026` and ISO through one ordered format list — legal documents love spelling months out.                              |
| **Regex value type**           | `LX_SA_ID` extracts the 13-digit identity number from whatever text surrounds it, and fails loudly on anything else.                                             |
| Restricted picklists           | `Executrix` and `Cape Town` are validated against the picklist before the write.                                                                                 |

The child hop is the point. In a real deceased-estates org the file is filed
against the Case an agent is working, but the data belongs on the Estate Case.
[`IdpContextResolver`](../../main/default/classes/IdpContextResolver.cls)
resolves that in one pass, so no rule has to know how the two are joined.

```
ContentDocument ──linked to──► Case ──child hop──► Estate_Case__c
                                                   (Estate_Case__c.Case__c = :caseId)
```

## The document and the JSON

- [`documents/letters-of-executorship.pdf`](documents/letters-of-executorship.pdf)
  — what the administrator sees on the left of `fileJsonReview`.
- [`sample/extracted.json`](sample/extracted.json) — what the OCR/IDP service
  would have returned for it, and what you paste into **Source JSON**.

```json
{
  "letters":  { "estateNumber": "004521/2026", "issuedDate": "08/04/2026", "mastersOffice": "Cape Town", ... },
  "executor": { "fullName": "Nomsa Patience Dlamini", "identityNumber": "8203155009087", "capacity": "Executrix" },
  "deceased": { "fullName": "Johannes Petrus van der Merwe", "identityNumber": "5107085042083", "dateOfDeath": "14/02/2026" }
}
```

The JSON carries two paths the mapping ignores — `letters.formNumber` and
`letters.actReference`. A document says more than the data model needs, and an
unmapped path is simply not read.

## The configuration

Mapping set: **`Letters_Of_Executorship`**

### Sections ([`customMetadata/`](customMetadata))

| Section       | Type  | Target object    |
| ------------- | ----- | ---------------- |
| `Appointment` | Fixed | `Estate_Case__c` |
| `Deceased`    | Fixed | `Estate_Case__c` |

### Rules

| Section       | `jsonPath`                | Target field (`Estate_Case__c`) | Policy            | Value Type   |
| ------------- | ------------------------- | ------------------------------- | ----------------- | ------------ |
| `Appointment` | `letters.estateNumber`    | `Estate_Number__c`              | Always (Required) |              |
| `Appointment` | `letters.issuedDate`      | `Letters_Issued_Date__c`        | Always            | `LX_Date_ZA` |
| `Appointment` | `letters.mastersOffice`   | `Masters_Office__c`             | Always            |              |
| `Appointment` | `executor.fullName`       | `Executor_Full_Name__c`         | Always            |              |
| `Appointment` | `executor.identityNumber` | `Executor_ID_Number__c`         | Always            | `LX_SA_ID`   |
| `Appointment` | `executor.capacity`       | `Appointment_Capacity__c`       | Always            |              |
| `Deceased`    | `deceased.fullName`       | `Deceased_Full_Name__c`         | Always            |              |
| `Deceased`    | `deceased.identityNumber` | `Deceased_ID_Number__c`         | Always            | `LX_SA_ID`   |
| `Deceased`    | `deceased.dateOfDeath`    | `Date_Of_Death__c`              | Always            | `LX_Date_ZA` |

A letter without an estate number is not usable, so that rule is flagged
**Required**: a document lacking the path produces an error finding instead
of a silent skip.

### Custom fields ([`objects/`](objects))

Nine custom fields, all on `Estate_Case__c`:

- **Text** — `Estate_Number__c`, `Executor_Full_Name__c`,
  `Executor_ID_Number__c`, `Deceased_Full_Name__c`, `Deceased_ID_Number__c`
- **Date** — `Letters_Issued_Date__c`, `Date_Of_Death__c`
- **Restricted picklist** — `Masters_Office__c` (the Master's offices),
  `Appointment_Capacity__c` (Executor / Executrix / Master's Representative)

Permission set **`IDP_Example_Letters_Of_Executorship`** grants read/edit on
all nine plus read/create/edit on `Estate_Case__c`. Without it the engine
reports `No update access to …` instead of writing, because it applies
`stripInaccessible` before every save.

## Prerequisite: `Estate_Case__c`

**This example assumes `Estate_Case__c` already exists in the org**, because
that is what a real deceased-estates org has and what the
[Liquidity Calculator](https://github.com/smelgin/lqc/blob/main/LIQUIDITY_CALCULATOR.md#81-prerequisite-estate_case__c)
also expects. The example adds only the nine fields — the Estate Case record
itself is created by the data import, with those fields blank.

If your org **does not** have it (a fresh scratch org, say), deploy the
minimal stand-in first — it creates the object with a Text `Name` and a
`Case__c` lookup, and nothing else:

```bash
sf project deploy start --source-dir force-app/idp/examples/bootstrap/estate-case --target-org <alias>
```

> Run that command **only** if the object is missing. In an org that already
> has `Estate_Case__c`, it would rewrite that object's label and sharing model.
> It also deliberately omits `LQC_Result__c`; the [lqc
> repository](https://github.com/smelgin/lqc) ships its own copy of this object
> with that field, if you want the Liquidity Calculator in the same org.
>
> This is why the stand-in lives in `examples/bootstrap/` rather than inside
> this example: `--source-dir` deploys a directory **and everything under it**,
> so an example-local `bootstrap/` folder would ride along with the example
> deploy below and clobber the object it is meant to protect.

### If your org already has `Estate_Case__c`

Two assumptions this example makes, both easy to adjust:

| Assumption                                | If yours differs                                                                                                                                                                                                      |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The lookup to Case is named **`Case__c`** | Edit `Case__c` in [`data/EstateCases.json`](data/EstateCases.json) and the `WHERE` clause in [`scripts/setup.apex`](scripts/setup.apex). The engine itself needs no change — it discovers the lookup from the schema. |
| **`Name`** is a writable Text field       | If it is an Auto Number, drop the `"Name"` line from `data/EstateCases.json` — the import sets it automatically.                                                                                                      |

Any **required** custom field or validation rule on your `Estate_Case__c` will
block the data import; the seed record only sets `Name` and `Case__c`.

## Deploy it

The engine itself has to be in the org first — deploy it once, then the
example. `<alias>` is your org alias throughout.

```bash
sf project deploy start --source-dir force-app/idp/main --target-org <alias>
```

```bash
sf project deploy start --source-dir force-app/idp/examples/letters-of-executorship --target-org <alias>
```

```bash
sf org assign permset --name IDP_Example_Letters_Of_Executorship --target-org <alias>
```

That deploy carries the nine fields, the eleven metadata records and the
permission set — and nothing else. It never touches the `Estate_Case__c`
object definition itself.

## Load the data

One Account for the estate relationship, the intake Case, and an Estate Case
whose nine fields are all blank:

```bash
sf data import tree --plan force-app/idp/examples/letters-of-executorship/data/plan.json --target-org <alias>
```

Find the Case the file has to hang off:

```bash
sf data query --query "SELECT Id, CaseNumber FROM Case WHERE Subject = 'Letters of Executorship received - Estate Late J P van der Merwe'" --target-org <alias>
```

Upload the scanned Letters to it, substituting the Id you just got:

```bash
sf data create file --file force-app/idp/examples/letters-of-executorship/documents/letters-of-executorship.pdf --title "Letters of Executorship" --parent-id <caseId> --target-org <alias>
```

Finally print the `ContentDocumentId` the component needs. This also repairs
the link if the upload went elsewhere, and walks the same child hop the engine
will walk — so if it prints an Estate Case, the mapping will find one too:

```bash
sf apex run --file force-app/idp/examples/letters-of-executorship/scripts/setup.apex --target-org <alias>
```

## Run it

Drop **File JSON Review + Field Mapping Demo** (`fileJsonReviewMappingDemo`)
on any App or Home page and set:

| Property            | Value                                   |
| ------------------- | --------------------------------------- |
| Content Document Id | the Id printed by `setup.apex`          |
| Source JSON         | the contents of `sample/extracted.json` |
| Mapping Set         | `Letters_Of_Executorship`               |
| Mode                | `Extraction`                            |

Review the form on the right — correcting what the OCR misread is the whole
point of the component, and handwritten Master's stamps are exactly what it
misreads — then press **Preview changes** and **Confirm & Save**. The toast
reports `9 field(s) applied to 1 record(s)`.

One record, not two: both sections target `Estate_Case__c`, so the nine values
merge into a single update. The Case the file is linked to is never written
to — it was only the way in.

The same thing works from a Screen Flow — host `fileJsonReview`, then call the
**Apply IDP Mapping Set** action with the same four values. See
[IDP_MAPPING.md](../../../../IDP_MAPPING.md#usage-from-a-screen-flow).

## Verify

```bash
sf data query --query "SELECT Name, Estate_Number__c, Letters_Issued_Date__c, Masters_Office__c, Executor_Full_Name__c, Executor_ID_Number__c, Appointment_Capacity__c, Deceased_Full_Name__c, Deceased_ID_Number__c, Date_Of_Death__c FROM Estate_Case__c WHERE Name = 'Estate Late J P van der Merwe'" --target-org <alias>
```

Expect `Date_Of_Death__c` = `2026-02-14` and `Letters_Issued_Date__c` =
`2026-04-08` — **8 April, not 4 August**. `08/04/2026` is the ambiguous date on
the page, and it reads correctly only because `LX_Date_ZA` declares day-first
formats.

## Things worth trying

- Change `executor.capacity` to `Trustee` and save again. That rule fails with
  _"Trustee" is not an active value of picklist Appointment_Capacity\_\_c_
  while the other eight fields still apply — the engine's partial-success
  behaviour.
- Change `letters.issuedDate` to `8 April 2026`, the way the Master's clerk
  actually writes it. It still parses — `LX_Date_ZA`'s format list carries
  `d MMMM yyyy`.
- Add `MM/dd/yyyy` to `LX_Date_ZA`'s Formats and re-run. `08/04/2026` now
  reads two ways, so the engine reports it **Ambiguous** and writes nothing —
  a silently wrong date is far worse than a rejected one, and v2 refuses to
  guess.
- Change `deceased.identityNumber` to `ID No: 5107085042083 (RSA)`. The
  `LX_SA_ID` regex still extracts the 13 digits.
- Delete the Estate Case and save again. Every rule reports that no
  `Estate_Case__c` could be resolved — the child hop found nothing, and the
  engine writes nothing rather than guessing.
- Link the file to the Estate Case **as well**. It anchors directly, no hop
  needed, and the result is identical — which is the point of resolving by
  schema rather than by configuration.

## Clean up

```bash
sf data delete record --sobject Estate_Case__c --where "Name='Estate Late J P van der Merwe'" --target-org <alias>
```

```bash
sf data delete record --sobject Case --where "Subject='Letters of Executorship received - Estate Late J P van der Merwe'" --target-org <alias>
```

```bash
sf data delete record --sobject Account --where "Name='Estate Late J P van der Merwe'" --target-org <alias>
```

---

_Back to the [examples index](../README.md) · engine reference:
[IDP_MAPPING.md](../../../../IDP_MAPPING.md)_
