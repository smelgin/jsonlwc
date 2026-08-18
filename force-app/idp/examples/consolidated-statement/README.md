# Example 2 — Consolidated Statement (Extraction, repeating section)

A month-end consolidated statement lists every product a business customer
holds: cheque account, call deposit, credit card, vehicle finance. The header
is one set of values; the products are a **repeating band** whose length
changes from customer to customer and month to month.

This example refreshes the stored balance, rate, status and opening date of
each product from the statement. It is the same **Data Extraction** mode as
[example 1](../business-account-opening/README.md), but with a **Repeating**
section next to the Fixed one — six rules serve four statement lines, and
would serve four hundred without a change.

## What it demonstrates

| Feature                    | Where to look                                                                                                            |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Repeating sections         | `Holdings` walks `Row_Path__c = holdings` and applies its rules once per row.                                            |
| Row-relative paths         | Rules on `Holdings` read `currentBalance`, not `holdings[0].currentBalance`.                                             |
| Row matching               | `Match_Value__c = {row:accountNumber}` is looked up against `Asset.Product_Account_Number__c`.                           |
| `Parent_Section__c`        | Rows are constrained to the statement's own Account, so a key cannot reach another customer's products.                  |
| `Record_Filter__c`         | `Account_Status__c != 'Closed'` protects closed products; the closed row comes back in `unmatchedRowKeys`.               |
| Rows are never created     | A statement line with no matching record is reported, not inserted.                                                      |
| Fixed and repeating in one | The `Statement` header section writes the period end and total to the Account in the same call.                          |
| **Batch reprocessing**     | The statement JSON stored on `Account.Statement_JSON__c` reprocesses with `IdpBatchProcessor` — no user, no file needed. |

## The document and the JSON

- [`documents/consolidated-statement.pdf`](documents/consolidated-statement.pdf)
- [`sample/extracted.json`](sample/extracted.json)

```json
{
  "statement": { "periodEnd": "2026-07-31", "totalRelationshipBalance": 1284730.55 },
  "holdings": [
    { "accountNumber": "62110044721", "productName": "Business Cheque Account", "currentBalance": 184230.55, ... },
    { "accountNumber": "90071188420", ... },
    { "accountNumber": "45500219873", ... },
    { "accountNumber": "77012004466", ... }
  ]
}
```

`holdings` is the repeating band. Everything under `statement` is the fixed
header.

## The configuration

Mapping set: **`Consolidated_Statement`**

### Sections ([`customMetadata/`](customMetadata))

| Field               | `Statement` | `Holdings`                      |
| ------------------- | ----------- | ------------------------------- |
| `Section_Type__c`   | Fixed       | **Repeating**                   |
| `Target_Object__c`  | `Account`   | `Asset`                         |
| `Row_Path__c`       | —           | `holdings`                      |
| `Match_Field__c`    | —           | `Product_Account_Number__c`     |
| `Match_Value__c`    | —           | `{row:accountNumber}`           |
| `Record_Filter__c`  | —           | `Account_Status__c != 'Closed'` |
| `Parent_Section__c` | —           | `Statement`                     |

### Rules

| Section     | `JSON_Path__c`                       | Target field                            | Value Type   |
| ----------- | ------------------------------------ | --------------------------------------- | ------------ |
| `Statement` | `statement.periodEnd`                | `Account.Statement_Period_End__c`       | `CS_Date_ZA` |
| `Statement` | `statement.totalRelationshipBalance` | `Account.Total_Relationship_Balance__c` | `CS_Money`   |
| `Holdings`  | `productName`                        | `Asset.Name`                            |              |
| `Holdings`  | `currentBalance`                     | `Asset.Current_Balance__c`              | `CS_Money`   |
| `Holdings`  | `availableBalance`                   | `Asset.Available_Balance__c`            | `CS_Money`   |
| `Holdings`  | `interestRate`                       | `Asset.Interest_Rate__c`                |              |
| `Holdings`  | `openedDate`                         | `Asset.InstallDate`                     | `CS_Date_ZA` |
| `Holdings`  | `status`                             | `Asset.Account_Status__c`               |              |

`CS_Date_ZA` reads `22/06/2021` on the holdings and ISO `2026-07-31` on the
header through one ordered format list; `CS_Money` compares balances to the
cent in Compliance mode.

The six `Holdings` paths carry no `holdings[n]` prefix. Inside a repeating
section every path is read against the current row, which is exactly why the
rule count does not grow with the document.

### How a row finds its record

`Asset` is the natural standard object for "a product this customer holds", so
each statement line matches an Asset by the account number printed on it:

```
document row  { "accountNumber": "62110044721", … }
                        │
   Match_Value {row:accountNumber} renders "62110044721"
                        │
   SELECT … FROM Asset WHERE Product_Account_Number__c IN (…)
                         AND AccountId = <the statement's Account>
                         AND (Account_Status__c != 'Closed')
```

The `AccountId` condition comes from `Parent_Section__c = Statement`: the
`Statement` section resolves to the Account the file is linked to, and the
engine discovers `Asset.AccountId` as the lookup back to it. All four keys are
matched in **one query**, and all matched rows are saved in **one DML** — a
two-line statement and a two-hundred-line one cost the same.

### Custom fields ([`objects/`](objects))

- **Account** — `Statement_Period_End__c`, `Total_Relationship_Balance__c`,
  `Statement_JSON__c` (long text — the batch input, see below)
- **Asset** — `Product_Account_Number__c` (the match field, flagged as an
  External Id), `Current_Balance__c`, `Available_Balance__c`,
  `Interest_Rate__c` (Percent), `Account_Status__c` (restricted picklist)

`Match_Field__c` does _not_ have to be an External Id — rows are matched with a
plain SOQL query, so any queryable field works. It is one here only because an
account number genuinely is an external key.

Permission set: **`IDP_Example_Consolidated_Statement`**.

## Deploy it

```bash
sf project deploy start --source-dir force-app/idp/main --target-org <alias>
```

```bash
sf project deploy start --source-dir force-app/idp/examples/consolidated-statement --target-org <alias>
```

```bash
sf org assign permset --name IDP_Example_Consolidated_Statement --target-org <alias>
```

## Load the data

One Account and four Assets carrying **last month's** figures, so the run has
something visible to change. The fourth is already `Closed`:

```bash
sf data import tree --plan force-app/idp/examples/consolidated-statement/data/plan.json --target-org <alias>
```

The statement covers the whole relationship rather than one case, so it hangs
off the Account:

```bash
sf data query --query "SELECT Id, Name FROM Account WHERE Name = 'Cape Meridian Logistics'" --target-org <alias>
```

```bash
sf data create file --file force-app/idp/examples/consolidated-statement/documents/consolidated-statement.pdf --title "Consolidated Statement" --parent-id <accountId> --target-org <alias>
```

```bash
sf apex run --file force-app/idp/examples/consolidated-statement/scripts/setup.apex --target-org <alias>
```

The script prints the `ContentDocumentId` and the four rows as they stand
before the run.

## Run it

Host **File JSON Review + Field Mapping Demo** and set:

| Property            | Value                                   |
| ------------------- | --------------------------------------- |
| Content Document Id | the Id printed by `setup.apex`          |
| Source JSON         | the contents of `sample/extracted.json` |
| Mapping Set         | `Consolidated_Statement`                |
| Mode                | `Extraction`                            |

Press **Preview changes**, check the planned old → new table, then **Confirm
& Save**.

> **Read the row counters from a Flow.** The demo LWC reports fields,
> mismatches and errors, but not `rowsMatched`, `rowsUpdated` or
> `unmatchedRowKeys`. A Screen Flow calling the **Apply IDP Mapping Set**
> action can display all three directly, and for a repeating section they are
> the interesting numbers.

Expected result: `rowsMatched` 3, `rowsUpdated` 3, and

```
unmatchedRowKeys: ["77012004466"]
```

That last one is the vehicle finance line. It is on the statement and it does
exist in Salesforce, but `Record_Filter__c` excludes closed products, so the
engine reports it instead of touching it. An unmatched key is **data, not an
error** — `result.success` stays `true`. In a real deployment it is exactly
the signal you would route to an exception queue.

## Verify

```bash
sf data query --query "SELECT Product_Account_Number__c, Name, Current_Balance__c, Available_Balance__c, Interest_Rate__c, InstallDate, Account_Status__c FROM Asset WHERE Account.Name = 'Cape Meridian Logistics' ORDER BY Product_Account_Number__c" --target-org <alias>
```

```bash
sf data query --query "SELECT Name, Statement_Period_End__c, Total_Relationship_Balance__c FROM Account WHERE Name = 'Cape Meridian Logistics'" --target-org <alias>
```

The credit card should have moved to `In Arrears` with a balance of
`-32500.00`; the vehicle finance row should still show last month's
`205000.00` and no `InstallDate`.

## Things worth trying

- Clear `Record_Filter__c` on the `Holdings` section and re-run. All four rows
  match and `unmatchedRowKeys` comes back empty.
- Duplicate a `holdings` entry in the JSON. The second copy renders the same
  Match Value, so it is skipped and reported rather than silently overwriting
  the first — two lines can never collapse onto one record unnoticed.
- Add a fifth `holdings` entry with an invented account number. It appears in
  `unmatchedRowKeys`: this version of the engine matches and updates rows, and
  never creates them.
- Switch **Mode** to `Compliance` and re-run. Nothing is written, and each
  mismatch now carries `sectionName`, `rowIndex` and `rowKey`, so the report
  names the statement line that disagrees rather than just the field. A
  balance off by less than a cent comes back as **Near** rather than
  Mismatch — `CS_Money`'s Compare Tolerance at work.

## Run it in batch

The mapping set's **JSON Source Field** is `Account.Statement_JSON__c`, so the
same statement can be reprocessed with no user and no file. Paste the sample
JSON onto the Account and run the batch:

```bash
sf data query --query "SELECT Id FROM Account WHERE Name = 'Cape Meridian Logistics'" --target-org <alias>
```

Then in Anonymous Apex (Developer Console or `sf apex run`):

```apex
Account statementHolder = [SELECT Id FROM Account WHERE Name = 'Cape Meridian Logistics'];
statementHolder.Statement_JSON__c = /* contents of sample/extracted.json */;
update statementHolder;
Database.executeBatch(new IdpBatchProcessor('Consolidated_Statement'), 10);
```

The engine seeds each document from its record (`Account` here) instead of a
file, resolves the same anchors, and matches the same rows — the batch path
and the interactive path are one pipeline.

The mapping set also names `Statement_Processed__c` as its **Processed
Marker Field**, which makes the batch idempotent: only Accounts where the
marker is blank are picked up, and each is stamped once processed. Run the
batch twice and the second run touches nothing. To reprocess after a rule
change, pass `reprocessAll`:

```apex
Database.executeBatch(
  new IdpBatchProcessor('Consolidated_Statement', null, null, null, true), 10);
```

Documents the governor-limits guard deferred are left unstamped, and the
batch chains one retry pass for exactly those records.

## Clean up

```bash
sf data delete record --sobject Account --where "Name='Cape Meridian Logistics'" --target-org <alias>
```

Assets are children of the Account and go with it.

---

_Back to the [examples index](../README.md) · engine reference:
[IDP_MAPPING.md](../../../../IDP_MAPPING.md#sections-fixed-and-repeating-regions)_
