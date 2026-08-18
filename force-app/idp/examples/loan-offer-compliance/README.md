# Example 3 — Loan Offer Compliance (Compliance, fixed sections, custom handler)

A borrower returns a signed term-loan offer letter. Before anything is
disbursed, somebody has to confirm that the terms printed on the page they
signed are the terms the bank actually approved — the same principal, the same
rate, the same repayment.

That is not an extraction problem. Nothing on this document should be written
anywhere; the document is the claim, and Salesforce is the record. So this
example runs the engine in **Compliance Check** mode, where it compares
instead of writing, and hands whatever it finds to a custom
[`IIdpFindingHandler`](classes/LoanOfferMismatchHandler.cls).

The seed data is rigged so the check fails in three instructive ways.

## What it demonstrates

| Feature                        | Where to look                                                                                                                                                                           |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Compliance mode                | Two Fixed sections, nine rules, zero DML from the engine itself.                                                                                                                        |
| Set-level defaults             | The mapping set declares `Default_Mode__c = Compliance` **and** its own `Finding_Handler__c`, so the caller configures nothing.                                                         |
| Per-rule `Mode__c`             | Every rule additionally pins `Mode__c = Compliance`, so this set can never write even if run in Extraction mode.                                                                        |
| Both-sides comparison          | `KALAHARI FREIGHT SERVICES` matches the stored `Kalahari Freight Services`; `"R 2 400 000.00"` matches the stored `2400000.00` — both sides go through the value type's canonical form. |
| Three-state verdicts           | `LO_Money_ZA` has a one-cent Compare Tolerance: a rounding difference is **Near**, not a Mismatch.                                                                                      |
| Blank counts as a mismatch     | The empty `Credit_Risk_Grade__c` cannot confirm the document, so it is reported.                                                                                                        |
| `IIdpFindingHandler`           | `LoanOfferMismatchHandler` stamps the Case and raises a high-priority Task.                                                                                                             |
| Mismatches are data, not error | `result.success` stays `true`; `result.compliant` goes `false`.                                                                                                                         |

## The document and the JSON

- [`documents/loan-offer-letter.pdf`](documents/loan-offer-letter.pdf)
- [`sample/extracted.json`](sample/extracted.json)

```json
{
  "borrower": { "registeredName": "KALAHARI FREIGHT SERVICES", "creditRiskGrade": "BB", ... },
  "offer": {
    "reference": "LN-2026-093315",
    "principalAmount": "R 2 400 000.00",
    "interestRate": 12.05,
    "termMonths": 60,
    "monthlyRepayment": "R 53 480.19",
    "expiryDate": "31/08/2026"
  }
}
```

## The configuration

Mapping set: **`Loan_Offer_Compliance`**

### Sections ([`customMetadata/`](customMetadata))

| Section    | Type  | Target object |
| ---------- | ----- | ------------- |
| `Borrower` | Fixed | `Account`     |
| `Offer`    | Fixed | `Case`        |

No repeating section: an offer letter is a single set of terms.

### Rules

| Section    | `JSON_Path__c`                    | Compared against                      | Value Type    |
| ---------- | --------------------------------- | ------------------------------------- | ------------- |
| `Borrower` | `borrower.registeredName`         | `Account.Name`                        |               |
| `Borrower` | `borrower.creditRiskGrade`        | `Account.Credit_Risk_Grade__c`        |               |
| `Borrower` | `borrower.verifiedAnnualTurnover` | `Account.Verified_Annual_Turnover__c` | `LO_Money_ZA` |
| `Offer`    | `offer.reference`                 | `Case.Offer_Reference__c`             |               |
| `Offer`    | `offer.principalAmount`           | `Case.Loan_Amount__c`                 | `LO_Money_ZA` |
| `Offer`    | `offer.interestRate`              | `Case.Interest_Rate_Offered__c`       |               |
| `Offer`    | `offer.termMonths`                | `Case.Loan_Term_Months__c`            |               |
| `Offer`    | `offer.monthlyRepayment`          | `Case.Repayment_Amount__c`            | `LO_Money_ZA` |
| `Offer`    | `offer.expiryDate`                | `Case.Offer_Expiry_Date__c`           | `LO_Date_ZA`  |

Every one of them sets `Mode__c = Compliance` rather than leaving it blank to
inherit the run's mode. That is deliberate: a mapping set that exists to
_verify_ a legal document should not become a mapping set that _overwrites_
the approved terms because somebody left the Mode picklist on its default.
Pinning it per rule makes that mistake impossible.

### The nine comparisons, and why three fail

| Field                                 | Document                  | Seeded record             | Result                                              |
| ------------------------------------- | ------------------------- | ------------------------- | --------------------------------------------------- |
| `Account.Name`                        | KALAHARI FREIGHT SERVICES | Kalahari Freight Services | ✅ case and spacing are normalized                  |
| `Account.Credit_Risk_Grade__c`        | `BB`                      | _(blank)_                 | ❌ a blank field confirms nothing                   |
| `Account.Verified_Annual_Turnover__c` | `R 14 750 000.00`         | `14750000.00`             | ✅ compared as numbers                              |
| `Case.Offer_Reference__c`             | `LN-2026-093315`          | `LN-2026-093315`          | ✅                                                  |
| `Case.Loan_Amount__c`                 | `R 2 400 000.00`          | `2400000.00`              | ✅ currency noise stripped                          |
| `Case.Interest_Rate_Offered__c`       | `12.05`                   | `11.25`                   | ❌ **the terms really do differ**                   |
| `Case.Loan_Term_Months__c`            | `60`                      | `60`                      | ✅                                                  |
| `Case.Repayment_Amount__c`            | `R 53 480.19`             | `51902.44`                | ❌ **follows from the rate**                        |
| `Case.Offer_Expiry_Date__c`           | `31/08/2026`              | `2026-08-31`              | ✅ parsed by the value type, then compared as dates |

The first, third, fifth and last rows are the point of the comparison rules:
OCR output never matches stored formatting exactly, and a checker that flagged
`R 2 400 000.00` against `2400000.00` would be useless. The two real
differences — a rate that moved 80 basis points between approval and
signature, and the repayment that follows from it — are what a human needs to
see.

## The custom handler

[`LoanOfferMismatchHandler`](classes/LoanOfferMismatchHandler.cls) implements
the one-method contract:

```apex
public interface IIdpFindingHandler {
    void handle(IdpResult.RunReport report);
    // report: mappingSetName, mode, and every document's full Result —
    // mismatches, near matches, errors, row context
}
```

It is registered on the mapping set's `Finding_Handler__c` (a caller-supplied
name overrides it) and instantiated with `Type.forName`, so the engine has no
compile-time knowledge of it. On a failing run it:

1. groups the differences by object and renders a readable breakdown;
2. stamps `Case.Offer_Verification_Status__c = Mismatched` and writes the
   breakdown to `Case.Offer_Verification_Notes__c`;
3. raises one **High** priority Task on the Case carrying the same text.

> **"Compliance writes nothing" — but this handler writes.** The _engine_
> performs no DML in Compliance mode; the mapping rules are read-only, and
> nothing the document claims is ever copied onto a record. What the handler
> does afterwards is the org's own decision, taken in Apex you control. Here
> that decision is to record a verification outcome and put the difference in
> somebody's queue — neither of which copies the document's values onto the
> loan.

This is the difference from the bundled `IdpComplianceTaskHandler`, which only
creates a Task. Use whichever is closer to what you need as a starting point.
Handlers run in the same transaction as the check; if one throws, the failure
becomes a `HANDLER_FAILED` finding and the mismatches still come back on the
`Result`, so a hosting Flow or LWC can react whether or not a handler is
configured.

### Custom fields ([`objects/`](objects))

- **Account** — `Credit_Risk_Grade__c`, `Verified_Annual_Turnover__c`
- **Case** — `Offer_Reference__c`, `Loan_Amount__c`,
  `Interest_Rate_Offered__c`, `Loan_Term_Months__c`, `Repayment_Amount__c`,
  `Offer_Expiry_Date__c`, plus `Offer_Verification_Status__c` and
  `Offer_Verification_Notes__c`, which only the handler writes.

Permission set **`IDP_Example_Loan_Offer_Compliance`** grants read on the
compared fields, edit on the two the handler stamps, and Apex class access to
the handler.

## Deploy it

```bash
sf project deploy start --source-dir force-app/idp/main --target-org <alias>
```

The example ships Apex, so deploy it with its test class running — this is the
command to use against production:

```bash
sf project deploy start --source-dir force-app/idp/examples/loan-offer-compliance --target-org <alias> --test-level RunSpecifiedTests --tests LoanOfferMismatchHandlerTest
```

```bash
sf org assign permset --name IDP_Example_Loan_Offer_Compliance --target-org <alias>
```

## Load the data

One Account with a blank risk grade, and one Case carrying the **approved**
terms — two of which the signed document contradicts:

```bash
sf data import tree --plan force-app/idp/examples/loan-offer-compliance/data/plan.json --target-org <alias>
```

```bash
sf data query --query "SELECT Id, CaseNumber FROM Case WHERE Subject = 'Signed loan offer received - Kalahari Freight Services'" --target-org <alias>
```

```bash
sf data create file --file force-app/idp/examples/loan-offer-compliance/documents/loan-offer-letter.pdf --title "Signed Loan Offer Letter" --parent-id <caseId> --target-org <alias>
```

```bash
sf apex run --file force-app/idp/examples/loan-offer-compliance/scripts/setup.apex --target-org <alias>
```

The script prints the `ContentDocumentId` and every stored term, marking the
three that are about to be reported.

## Run it

Host **File JSON Review + Field Mapping Demo** and set:

| Property            | Value                                   |
| ------------------- | --------------------------------------- |
| Content Document Id | the Id printed by `setup.apex`          |
| Source JSON         | the contents of `sample/extracted.json` |
| Mapping Set         | `Loan_Offer_Compliance`                 |
| Mode                | `Compliance`                            |

No handler property needed: the mapping set itself names
`LoanOfferMismatchHandler` as its Finding Handler.

The button now reads **Check compliance**. Press it and the demo shows a
mismatch table under the review pane:

```
Account.Credit_Risk_Grade__c    stored (blank)   extracted BB
Case.Interest_Rate_Offered__c   stored 11.25     extracted 12.05
Case.Repayment_Amount__c        stored 51902.44  extracted 53480.19
```

`9 field(s) checked, 3 mismatch(es)`. Nothing was written by the engine.

## Verify the handler ran

```bash
sf data query --query "SELECT CaseNumber, Offer_Verification_Status__c, Offer_Verification_Notes__c FROM Case WHERE Subject = 'Signed loan offer received - Kalahari Freight Services'" --target-org <alias>
```

```bash
sf data query --query "SELECT Subject, Priority, ActivityDate, Description FROM Task WHERE Subject = 'Verify signed loan offer against the system record'" --target-org <alias>
```

## Things worth trying

- Correct `Case.Interest_Rate_Offered__c` to `12.05` and
  `Repayment_Amount__c` to `53480.19`, fill in `Credit_Risk_Grade__c` with
  `BB`, and re-run. `compliant` comes back `true` and the handler is never
  invoked.
- Set `Repayment_Amount__c` to `53480.18` — one cent off — and re-run. It
  comes back **Near** instead of Mismatch (`LO_Money_ZA`'s tolerance), listed
  for context but not blocking: rounding is not a changed term.
- Set **Mode** to `Extraction` and run. Nothing is written anyway, because
  every rule pins `Mode__c = Compliance`. Blank one rule's `Mode__c` and try
  again to see the difference.
- Set the **Finding Handler Class** property to a class that does not
  implement the interface. The engine reports a `HANDLER_FAILED` finding
  rather than failing the run — and the caller-supplied name overrides the
  set's default, which is the override order you want in a sandbox.

## Clean up

```bash
sf data delete record --sobject Case --where "Subject='Signed loan offer received - Kalahari Freight Services'" --target-org <alias>
```

```bash
sf data delete record --sobject Account --where "Name='Kalahari Freight Services'" --target-org <alias>
```

---

_Back to the [examples index](../README.md) · engine reference:
[IDP_MAPPING.md](../../../../IDP_MAPPING.md#modes)_
