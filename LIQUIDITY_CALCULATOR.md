# Liquidity Calculator (LQC) — Developer Manual

**Version 2.0** · API 66.0 · Audience: Salesforce developers

The Liquidity Calculator is a configuration-driven Lightning Web Component for Case record
pages. It renders a tab set where each tab is an editable grid, plus a calculated report tab
that summarizes the others. **Everything visible — tabs, columns, data types, widths, picklist
values, the report layout — is driven by a single JSON document stored in Custom Metadata.**
Adding a tab or a column is a metadata change, not a code change.

---

## Table of contents

1. [What it looks like](#1-what-it-looks-like)
2. [Architecture](#2-architecture)
3. [How the pieces talk to each other](#3-how-the-pieces-talk-to-each-other)
4. [Configuration reference](#4-configuration-reference) — including [where the result is stored](#44-where-the-result-is-stored-storage)
5. [The fieldKey convention](#5-the-fieldkey-convention)
6. [Writing a prefill class (ILqcPrefill)](#6-writing-a-prefill-class-ilqcprefill)
7. [The saved payload (Estate_Case__c.LQC_Result__c)](#7-the-saved-payload-estate_case__clqc_result__c)
8. [Deploying to another org or sandbox](#8-deploying-to-another-org-or-sandbox)
9. [Common tasks](#9-common-tasks)
10. [Testing](#10-testing)
11. [Known limitations and design decisions](#11-known-limitations-and-design-decisions)

---

## 1. What it looks like

A data tab — header with the configured title, the Add and Refresh actions, and the grid:

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ Debit Accounts │ Credit Accounts │ Insurance Policies │ … │ Estimated Estate Value│
├──────────────────────────────────────────────────────────────────────────────────┤
│  ✔ Fixed Properties Extract - Success           ← green banner (red when it fails)│
│ ┌──────────────────────────────────────────────────────────────────────────────┐ │
│ │ Debit Accounts                                          [+ Add]       [ ⟳ ] │ │
│ ├──────────────────────────────────────────────────────────────────────────────┤ │
│ │ Account Number    │ Account Type │ Available Balance │ Account Status │   ⋮   │ │
│ │ 0000006453… (link)│ Debit        │            13 000 │ Open           │   ▾   │ │
│ └──────────────────────────────────────────────────────────────────────────────┘ │
│                                                           [ Save ]  [ Publish ]  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

The report tab — grey section row per data tab, white summary lines, boxed grand total:

```
┌───────────────────────────────────┬────────────────────────┐
│ Estimated Net Estate Value                           [ ⟳ ] │
├───────────────────────────────────┼────────────────────────┤
│ Debit Accounts           (grey)   │                  Value │
│ Total                             │            R10 563 000 │
│ Insurance Policies       (grey)   │                  Value │
│ Life                              │             R1 500 000 │ ← grouped by groupBy
│ Home                              │             R2 500 000 │
├───────────────────────────────────┼────────────────────────┤
│ Estimated Net Estate Value        │            R14 563 000 │ ← bold, double height
└───────────────────────────────────┴────────────────────────┘
```

> **Screenshots.** The design mockups are not committed to this repo. If you have them, drop the
> PNGs into `docs/images/` using these names and the references in this document will resolve:
> `debit-accounts.png`, `credit-accounts.png`, `insurance-policies.png`, `fixed-properties.png`,
> `shares.png`, `estimated-estate-value.png`.

---

## 2. Architecture

### Component inventory

| Metadata                    | Path                                                                                                                            | Purpose                                                                                                                                                                        |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `liquidityCalculator`       | `force-app/lqc/main/default/lwc/liquidityCalculator/`                                                                           | **Container.** The only component exposed to App Builder. Loads config + saved state, renders the tab set, owns Save/Publish and the component-level banner.                   |
| `lqcGrid`                   | `force-app/lqc/main/default/lwc/lqcGrid/`                                                                                       | **One editable grid.** Header, Add + Refresh, add-row modal, per-tab banner. Fully reusable — hand it a tab config and it renders.                                             |
| `lqcDatatable`              | `force-app/lqc/main/default/lwc/lqcDatatable/`                                                                                  | `lightning-datatable` subclass adding the custom **`picklist`** cell type (display template + combobox edit template).                                                         |
| `lqcReport`                 | `force-app/lqc/main/default/lwc/lqcReport/`                                                                                     | **Calculated report tab.** A pure function of the other tabs' rows. Never persisted.                                                                                           |
| `lqcBanner`                 | `force-app/lqc/main/default/lwc/lqcBanner/`                                                                                     | Success / error / info bar, used at both LQC and tab level.                                                                                                                    |
| `lqcUtils`                  | `force-app/lqc/main/default/lwc/lqcUtils/`                                                                                      | Shared service module: `fieldKey`, `parseColumnType`, `picklistOptions`, `widthToPixels`, `reduceError`.                                                                       |
| `LqcController`             | `force-app/lqc/main/default/classes/LqcController.cls`                                                                          | Apex controller: `getConfig`, `getSavedResult`, `saveResult`, `refreshRows`.                                                                                                   |
| `ILqcPrefill`               | `force-app/lqc/main/default/classes/ILqcPrefill.cls`                                                                            | Interface every refresh provider implements.                                                                                                                                   |
| `ILqcStorage`               | `force-app/lqc/main/default/classes/ILqcStorage.cls`                                                                            | Pluggable persistence strategy — decides _where_ the payload lives.                                                                                                            |
| `LqcEstateCaseStorage`      | `force-app/lqc/main/default/classes/LqcEstateCaseStorage.cls`                                                                   | Default strategy: `Estate_Case__c.LQC_Result__c` on the Estate Case related to the Case.                                                                                       |
| `Lqc*` providers            | `force-app/lqc/main/default/classes/Lqc{DebitAccounts,CreditAccounts,InsurancePolicies,FixedProperties,Shares,OtherAssets}.cls` | Prefill implementations. **Debit/Credit/Insurance query Financial Services Cloud** (see §6.1); FixedProperties/Shares/OtherAssets are still stubs.                             |
| `LqcFscService`             | `force-app/lqc/main/default/classes/LqcFscService.cls`                                                                          | Shared FSC access: resolves the Deceased Account from `Case.Account__c` and queries their Financial Accounts (owned, joint, or role-linked). Carries the FFLIB adoption notes. |
| `Custom_Configuration__mdt` | `force-app/lqc/main/default/objects/Custom_Configuration__mdt/`                                                                 | Shared CMT holding the JSON in `Value__c` (Long Text Area, 131 072).                                                                                                           |
| `DE_LQC` record             | `force-app/lqc/main/default/customMetadata/Custom_Configuration.DE_LQC.md-meta.xml`                                             | The configuration record. Label **DE Liquidity Calculator**.                                                                                                                   |

### Two things the repo does _not_ contain

1. **`Estate_Case__c`, its `LQC_Result__c` field, and its lookup to Case** — the storage
   destination. Assumed to already exist in the target org; see [§8.1](#81-prerequisite-estate_case__c).
2. **Page layout / Lightning page assignment** — you add the component in App Builder after deploy.

---

## 3. How the pieces talk to each other

```
                    Custom_Configuration__mdt (DE_LQC.Value__c)
                                  │  getConfig()
                                  ▼
                        liquidityCalculator
                     │        │            ▲
   save/getSavedResult│       │ config     │ rowschange { name, rows }
                     ▼        ▼            │
             LqcController  ┌── lqcGrid ───┘          (one per data tab)
                     │      │      │ refreshRows(className, recordId)
       Type.forName  │      │      ▼
                     ▼      │   LqcController ─► Type.forName ─► ILqcPrefill.refresh()
              ILqcStorage   │
                     │      └── lqcReport ◄─ rowsMap (live, in-memory only)
                     ▼
      LqcEstateCaseStorage ──► Estate_Case__c.LQC_Result__c
```

Key flows:

- **Load** — `connectedCallback` fires `getConfig` and `getSavedResult` in parallel. Saved rows
  are handed to each grid as `initialRows`.
- **Mutation** — every add / edit / delete / refresh in a grid dispatches `rowschange`. The
  container merges it into `tabRowsMap`, which is bound to `lqcReport`, so the report
  recalculates immediately.
- **Save / Publish** — the container serializes `tabRowsMap` and writes it to the Case.
- **Refresh** — the grid calls Apex, which instantiates the configured class by name and returns
  its rows. Prefilled rows are **replaced**; manually added rows survive.

---

## 4. Configuration reference

The whole component is one JSON document in `Custom_Configuration__mdt.Value__c`, on the record
with `DeveloperName = DE_LQC`. Shape:

```jsonc
{
  "tabs": [
    {
      "name": "debitAccount", // required, unique — key in the saved payload
      "title": "Debit Accounts", // required — tab label and grid header
      "refreshClass": "lqcDebitAccounts", // Apex class implementing ILqcPrefill
      "canAddRows": true, // default true; false disables "+ Add"
      "columns": [/* see below */]
    },
    {
      "name": "estimatedEstateValue",
      "title": "Estimated Estate Value", // tab label
      "type": "report", // ← marks the calculated report tab
      "reportTitle": "Estimated Net Estate Value", // optional card-header override
      "currencyCode": "ZAR" // optional ISO code → "R10 563 000"
    }
  ]
}
```

### 4.1 Tab keys

| Key            | Required    | Notes                                                                                                                             |
| -------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `name`         | ✅          | Unique, stable. Used as the key in `LQC_Result__c` — **renaming it orphans previously saved rows.**                               |
| `title`        | ✅          | Tab label; also the grid header and the report's section label.                                                                   |
| `columns`      | data tabs   | Omit on the report tab. A non-report tab with no columns renders a placeholder body.                                              |
| `refreshClass` | optional    | Apex class name. If absent, the refresh icon is disabled. Matching is case-insensitive, so `"lqcShares"` resolves to `LqcShares`. |
| `canAddRows`   | optional    | Defaults to `true`. Set `false` to disable **+ Add**.                                                                             |
| `type`         | optional    | Only meaningful value: `"report"`.                                                                                                |
| `reportTitle`  | report only | Card header when it must differ from the tab label. Falls back to `title`.                                                        |
| `currencyCode` | report only | ISO 4217 code passed to `Intl.NumberFormat`. Omit for plain numbers.                                                              |

### 4.2 Column keys

| Key        | Required      | Notes                                                                                                                            |
| ---------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `name`     | ✅            | Column header **and** the source of the row key — see [§5](#5-the-fieldkey-convention).                                          |
| `type`     | ✅            | See the type table below.                                                                                                        |
| `width`    | optional      | Percentage string, e.g. `"20%"`. Converted to an initial pixel width against a 1200 px baseline; users can still drag to resize. |
| `values`   | picklist only | Pipe-separated: `"Open\|Closed\|Deferred"`. (The singular key `value` is also accepted, for backward compatibility.)             |
| `subtotal` | optional      | `true` marks the column the report sums for this tab. Only **one** per tab is used, and it must be a number type.                |
| `groupBy`  | optional      | `true` makes the report group this tab's subtotal by this column's value instead of showing a single "Total" line.               |

### 4.3 Column types

| `type`        | Renders as                             | Editable     | Notes                                                                                                                 |
| ------------- | -------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------- |
| `text`        | Plain text                             | ✅           | Default when `type` is missing or unrecognized.                                                                       |
| `textLink`    | Hyperlink opening a new Salesforce tab | ❌ **never** | Link target comes from a `<key>RecordId` value supplied by the prefill class. Manually added rows leave it blank.     |
| `number`      | Right-aligned number, up to 2 decimals | ✅           |                                                                                                                       |
| `number(p,s)` | Right-aligned number, `s` decimals     | ✅           | `p` = max integer digits, `s` = decimals. `number(6,2)` → step `0.01`, max `999999.99` enforced in the add-row modal. |
| `date`        | Locale date (`date-local`)             | ✅           | Supply as `YYYY-MM-DD`.                                                                                               |
| `picklist`    | Text; combobox when editing            | ✅           | Options from `values`.                                                                                                |

Editability is **per row, not per column**: prefilled rows are always locked; only manually added
rows are editable and deletable. `textLink` is never editable in either case.

### 4.4 Where the result is stored (`storageClass`)

Persistence is a **pluggable strategy**, resolved by name exactly like `refreshClass`:

```jsonc
{
  "storageClass": "lqcEstateCaseStorage", // optional; this is the default
  "tabs": [/* … */]
}
```

The shipped strategy, **`LqcEstateCaseStorage`**, stores the payload in
**`Estate_Case__c.LQC_Result__c`** on the Estate Case related to the Case the component sits on —
so nothing is written to Case itself. It:

- finds the Estate Case through the lookup on `Estate_Case__c` that references `Case`,
  **auto-discovered from the schema** (a field named `Case__c` wins; otherwise the single field
  that references Case), so the class needs no edit if your lookup is named differently;
- **creates** the Estate Case on first save and reuses it afterwards (upsert, never duplicates);
- returns `null` on load when no Estate Case exists yet.

To store somewhere else, write a class implementing [`ILqcStorage`](#71-writing-a-storage-strategy)
and name it in `storageClass`. The class name comes from Custom Metadata, never from the browser.

### 4.5 The report tab

The report is entirely derived. For every tab in the config that has a number column flagged
`subtotal: true`, it emits:

1. A **grey section row**: tab `title` on the left, the literal label `Value` on the right.
2. **White summary rows** — one per distinct value of the `groupBy` column (blank values group
   under "Not specified"), or a single **`Total`** row when the tab has no `groupBy` column.
3. After all sections, a bold, double-height, boxed **`Estimated Net Estate Value`** row.

The grand total is a **simple sum** of every tab subtotal — no tab subtracts. Tabs without a
`subtotal` column (and the report tab itself) are skipped. Amounts are right-aligned throughout.

> The report is **never saved**. It recomputes from in-memory rows on every change, and its
> refresh icon simply forces a recalculation.

---

## 5. The fieldKey convention

**This is the contract between the JSON config, the Apex prefill classes, and the LWC.** Row data
is keyed by the camelCase form of the column's `name`:

| Column `name`        | Row key            |
| -------------------- | ------------------ |
| `Account Number`     | `accountNumber`    |
| `Balance at DoD`     | `balanceAtDod`     |
| `Share Name/Holding` | `shareNameHolding` |
| `Title Deed Nbr`     | `titleDeedNbr`     |

Algorithm: split on any run of non-alphanumeric characters, lowercase every word, capitalize all
but the first, join. It is implemented **twice** — `fieldKey()` in `lqcUtils.js` and
`LqcController.fieldKey()` in Apex — and the two **must stay in sync**. Both are unit tested.

⚠️ **Two columns whose labels reduce to the same key will collide.** Two columns both named
`Status` in one tab produce a single key, `status`, and share a value. Give them distinct labels.

For `textLink` columns, supply an extra key so the link resolves:

```apex
'accountNumber'         => '00000064536768635',   // the visible text
'accountNumberRecordId' => someRecord.Id          // → /lightning/r/<id>/view, opens in a new tab
```

---

## 6. Writing a prefill class (ILqcPrefill)

Refresh providers are resolved **dynamically by name** from the JSON config, so a new tab needs
no controller change.

```apex
public interface ILqcPrefill {
  List<Map<String, Object>> refresh(Id recordId);
}
```

Requirements for an implementation:

- **`public` (or `global`) with a no-argument constructor** — `Type.forName(...).newInstance()`
  cannot instantiate private or inner classes.
- Return one `Map<String, Object>` per row, keyed per [§5](#5-the-fieldkey-convention).
- `recordId` is the **Case Id** the component was placed on.
- Return an empty list (or `null`) for "no data" — do not throw for that case.
- Any exception you throw surfaces as a red banner reading `<Tab title> Extract - <your message>`,
  so keep messages user-appropriate.

Example against a real object:

```apex
public with sharing class LqcDebitAccounts implements ILqcPrefill {
  public List<Map<String, Object>> refresh(Id recordId) {
    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    for (Financial_Account__c fa : [
      SELECT Id, Name, Account_Number__c, Balance__c, Status__c
      FROM Financial_Account__c
      WHERE Case__c = :recordId
      WITH USER_MODE
    ]) {
      rows.add(
        new Map<String, Object>{
          'accountNumber' => fa.Account_Number__c,
          'accountNumberRecordId' => fa.Id, // makes the textLink clickable
          'accountName' => fa.Name,
          'balance' => fa.Balance__c,
          'accountStatus' => fa.Status__c
        }
      );
    }
    return rows;
  }
}
```

Register it by setting `"refreshClass": "lqcDebitAccounts"` on the tab. Values written to a
`picklist` column should match one of the configured `values`; an unmatched value still displays,
but the combobox will not preselect it.

> Three providers (`LqcFixedProperties`, `LqcShares`, `LqcOtherAssets`) still return hardcoded
> stub rows marked `TODO`. The other three are real — see §6.1. The interface will not change.

### 6.1 The FSC-backed providers (v2.1)

`LqcDebitAccounts`, `LqcCreditAccounts` and `LqcInsurancePolicies` query the **standard (core)
Financial Services Cloud data model** (API v61.0+ — `FinancialAccount`, `FinancialAccountParty`,
`FinancialAccountBalance`, not the `FinServ__*` managed-package objects), filtering on the
Deceased person's Account held in the **standard `Case.AccountId`** lookup (a Case without an
Account produces a clear red banner on refresh).

| Provider  | Source                                                                                                                     | Inclusion rule                                                                                                                    |
| --------- | -------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Debit     | `FinancialAccount` types `Checking`, `Savings`, `Investment`                                                               | Deceased has an **active Owner-role `FinancialAccountParty`** on the account (joint holdings are simply additional Owner parties) |
| Credit    | Same object, types `Credit Card`, `Loan`, `Mortgage`, `Automotive Loan`, `Automotive Lease`                                | Same rule                                                                                                                         |
| Insurance | `InsurancePolicy` where `NameInsuredId` = deceased; beneficiary from `InsurancePolicyParticipant` (`Role = 'Beneficiary'`) | Named-insured only                                                                                                                |

Key model facts encoded in `LqcFscService` (all commented in the code):

- **Ownership is a junction, not a lookup**: `FinancialAccountParty` with `Role = 'Owner'`.
  "Currently held" is filtered on the **`RoleStartDate`/`RoleEndDate` window, not
  `IsRoleActive`** — that field is read-only in the API and defaults to `false`, so filtering on
  it returns nothing unless an integration maintains it (and it cannot be seeded in Apex tests).
  If your org does maintain it, the class comment shows what to add. If parties are modeled
  against Contacts (`ContactId`), widen the query as noted there too.
- **Balances are read-only child records**: `FinancialAccountBalance` rows typed `Total Balance`,
  `Current Posted Balance`, `Available Credit`, etc.; the latest row (`BalanceAsOfDate`) per type
  wins. Debit tabs prefer `Current Posted Balance`→`Total Balance` for the available amount;
  credit tabs prefer the account's `TotalOutstandingAmount` field, then `Total Balance`. Because
  `Amount`/`Type`/`FinancialAccountId` are not createable, Apex tests cannot seed balances — the
  selection logic is unit-tested directly via `LqcFscService.balanceFor()`, and an org with no
  integration feeding these rows will show **blank balance columns** until one exists.
- **Group/household relations are excluded.** Accounts held by other members of the deceased's
  group (`AccountAccountRelation`) are not estate assets; the comment explains how to widen this.
- **Type sets are `@TestVisible` constants** — align them with the `FinancialAccount.Type`
  picklist values configured in your org (the core picklist guarantees only the Automotive
  values; the banking values come with FSC setup).
- **DoD balances**: FSC holds only current amounts; `balance` / `balanceAtDod` prefill the latest
  value until a statement-snapshot integration exists. `interestOnAcct` is left blank.
- **`coverAmount` maps to `PremiumAmount` as a placeholder** — point it at your real sum-insured
  source (custom field or `InsurancePolicyCoverage` aggregate) before trusting the subtotal.

Each class carries **FFLIB adoption notes**: extract the SOQL into `fflib_SObjectSelector`
subclasses resolved via the Application factory (mockable with ApexMocks), keep these classes as
row-mappers, and route any future DML through `fflib_ISObjectUnitOfWork` in `ILqcStorage`.

---

## 7. The saved payload (Estate_Case__c.LQC_Result__c)

**Save** and **Publish** both write this JSON:

```jsonc
{
  "version": 1, // payload schema version (unchanged since LQC v1)
  "published": false, // true after Publish → grids load read-only
  "savedAt": "2026-07-27T10:15:00.000Z",
  "tabs": {
    "debitAccount": [
      {
        "id": "debitAccount-prefill-0", // synthetic, unique within the tab
        "isManual": false, // false = came from refresh; true = user-added
        "editable": false, // drives cell-level editability
        "accountNumber": "0000006453…",
        "accountNumberRecordId": "500…",
        "balance": 3000
      }
    ],
    "shares": []
  }
}
```

Notes for anyone touching this:

- Rows are stored **exactly as rendered**, including the `id` / `isManual` / `editable`
  bookkeeping keys. Round-tripping is lossless.
- The report tab **never appears** in `tabs` — it is recalculated on load.
- **Publish is one-way in the UI.** It sets `published: true`, which disables Save, Publish, Add,
  Refresh and all editing on the next render. To unlock a Case, clear or edit `LQC_Result__c` on
  its Estate Case (Developer Console / data loader / anonymous Apex).
- Keys in `tabs` are tab `name` values. Renaming a tab in the config orphans its saved rows.
- The field must be large enough for realistic volumes — this was built against Long Text
  Area 131 072.

### 7.1 Writing a storage strategy

```apex
public interface ILqcStorage {
  String load(Id recordId); // null when nothing saved yet - do not throw
  void save(Id recordId, String payload);
}
```

`recordId` is always the **host record** the component sits on (the Case), never the destination
record — resolving one from the other is the strategy's job. Implementations must be `public` with
a no-argument constructor, and must enforce FLS/sharing themselves (`AccessLevel.USER_MODE`).
Name the class in the config's `storageClass` key; matching is case-insensitive.

This is the seam for future storage models — a generic key/value payload object shared across
features, a ContentVersion for payloads beyond 131 072 characters, or an external system — with no
change to the LWC or the controller.

---

## 8. Deploying to another org or sandbox

### 8.1 Prerequisite: Estate_Case__c

**Not in this repo — these must already exist in the target org**, because `LqcEstateCaseStorage`
references them at compile time. The deployment fails outright if they are missing:

| Metadata                              | Requirement                                                                                                                                                                                                                                                                                    |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Estate_Case__c`                      | Custom object, one record per Case.                                                                                                                                                                                                                                                            |
| `Estate_Case__c.LQC_Result__c`        | Long Text Area, large enough for the payload (131 072 recommended).                                                                                                                                                                                                                            |
| A lookup on `Estate_Case__c` → `Case` | Any API name; `Case__c` is preferred if several exist.                                                                                                                                                                                                                                         |
| **Financial Services Cloud**          | An FSC org with the standard objects enabled: `FinancialAccount`, `FinancialAccountParty`, `FinancialAccountBalance` (API v61.0+, Setup → Financial Accounts) and the Insurance objects (`InsurancePolicy`, `InsurancePolicyParticipant`) — the v2.1 providers reference them at compile time. |
| `Case.AccountId`                      | Standard field; must be populated with the Deceased person's Account for prefill to work.                                                                                                                                                                                                      |

Two things to check before the first save: the storage strategy creates an Estate Case when none
exists, so **every other field on `Estate_Case__c` must be optional** (a required custom field or
validation rule will block the insert), and the running user needs Create/Edit on the object.

The field does **not** need to be on any page layout — the component writes it directly — but the
running user needs **Edit** access to it (see [§8.4](#84-permissions)).

### 8.2 What to deploy

Everything under `force-app/lqc/main/default`:

| Type         | Items                                                                                                                                                                                                            |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| LWC          | `liquidityCalculator`, `lqcGrid`, `lqcDatatable`, `lqcReport`, `lqcBanner`, `lqcUtils`                                                                                                                           |
| Apex         | `LqcController`, `ILqcPrefill`, `ILqcStorage`, `LqcEstateCaseStorage`, `LqcDebitAccounts`, `LqcCreditAccounts`, `LqcInsurancePolicies`, `LqcFixedProperties`, `LqcShares`, `LqcOtherAssets`, `LqcControllerTest` |
| CMT          | `Custom_Configuration__mdt` + field `Value__c`                                                                                                                                                                   |
| CMT record   | `Custom_Configuration.DE_LQC`                                                                                                                                                                                    |
| Pre-existing | `Estate_Case__c` + `LQC_Result__c` + its Case lookup (see §8.1)                                                                                                                                                  |

`Custom_Configuration__mdt` is a **shared** metadata type — other features may already use it in
the target org. If it exists there, deploying the object/field again is a no-op as long as the
shapes match; if that org's `Value__c` is shorter than 131 072, widen it or the config will be
truncated. Only the `DE_LQC` record belongs to this feature.

### 8.3 Deploy

```bash
sf project deploy start --source-dir force-app/lqc --target-org <alias>
```

For a validation deploy to production, run the Apex tests:

```bash
sf project deploy start --source-dir force-app/lqc --target-org <alias> --test-level RunSpecifiedTests --tests LqcControllerTest
```

### 8.4 Permissions

`LqcController` runs `with sharing` and uses `WITH USER_MODE` / `AccessLevel.USER_MODE`, so the
running user genuinely needs:

- **Apex class access** to `LqcController` (profile or permission set).
- **Read on Case**, plus **Read/Create/Edit on `Estate_Case__c`** and **Edit on
  `Estate_Case__c.LQC_Result__c`** — FLS is enforced, so a read-only field produces a save error
  banner rather than a silent failure.
- Read access to whatever objects your real prefill classes query.

Custom Metadata records are readable by all users in Apex, so `Custom_Configuration__mdt` needs no
extra permission.

### 8.5 Add the component to the Case page

App Builder → open (or create) a Case Lightning Record Page → drag **Liquidity Calculator** onto
the page → optionally set **Config Developer Name** to point at a CMT record other than `DE_LQC`
→ Save and Activate. `recordId` is injected automatically.

### 8.6 Post-deploy checklist

1. Open a Case with the component. No red banner on load → config parsed and the Case read.
2. Click **⟳** on a data tab → green `<Title> Extract - Success` and stub rows appear.
3. Click **+ Add**, fill the modal (picklist columns render as dropdowns) → the row appears and is
   editable inline; prefilled rows are not.
4. Open **Estimated Estate Value** → sections and grand total reflect what you just entered.
5. **Save**, reload the page → rows come back. **Publish**, reload → everything is locked.

### 8.7 If the target org still has the old LQC_Config__mdt

LQC v1 used `LQC_Config__mdt.Config_JSON__c`; v2 replaced it and the files were removed from this
repo. Removing metadata from a repo does **not** delete it from an org — if the old type is still
there and you want it gone, run a destructive deploy:

`destructiveChanges.xml`

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>LQC_Config__mdt</members>
        <name>CustomObject</name>
    </types>
</Package>
```

```bash
sf project deploy start --metadata-dir <folder-with-destructiveChanges.xml-and-package.xml> --target-org <alias>
```

Confirm nothing else references it first.

---

## 9. Common tasks

### Add a new tab

1. Add an entry to `tabs[]` in `Custom_Configuration.DE_LQC.md-meta.xml` (unique `name`, `title`,
   `columns`, optional `refreshClass` / `canAddRows`).
2. If it needs prefill, create an `ILqcPrefill` class named exactly as `refreshClass`.
3. Deploy the CMT record (and the class). **No LWC change.**

### Add a column to an existing tab

Add the column object to that tab's `columns[]` and deploy the record. If it should be prefilled,
add the matching [`fieldKey`](#5-the-fieldkey-convention) to the maps your provider returns.
Previously saved rows simply have no value for the new key — they render blank.

### Change what the report sums

Move `"subtotal": true` to a different **number** column in that tab. Add or remove
`"groupBy": true` on a column to switch between grouped lines and a single `Total`.

### Store the payload somewhere else

Implement [`ILqcStorage`](#71-writing-a-storage-strategy), deploy the class, and set
`"storageClass": "<YourClass>"` in the config record. Nothing else changes.

### Add a brand-new column type

1. Handle the new `base` in `parseColumnType` (`lqcUtils.js`) if it takes parameters.
2. Add a `case` in the `columns` getter of `lqcGrid.js` mapping it to a datatable column.
3. If the datatable has no native equivalent, register a custom type in `lqcDatatable.js` with a
   display template and an `editTemplate` (mirror the `picklist` implementation).
4. Handle it in `handleAdd` so the add-row modal renders the right input.

### Unlock a published Case

```apex
// clears rows and the published flag
update new Estate_Case__c(Id = 'a0X...', LQC_Result__c = null);
```

To keep the data and only unlock, read the JSON, set `"published": false`, and write it back.

---

## 10. Testing

```bash
npm run test:unit          # Jest — 54 tests across the LQC bundles
npm run lint               # ESLint
npm run prettier:verify    # formatting
sf apex run test --target-org <alias> --class-names LqcControllerTest --result-format human
```

Jest specs live in `__tests__/` next to each bundle and cover: config→column mapping, picklist
option building, `number(p,s)` parsing, refresh replacing prefilled rows while keeping manual
ones, banner variants, the add-row modal, report grouping/totals/currency, and the published
lock. `LqcControllerTest` covers config lookup, the save round-trip, every stub provider,
`fieldKey` parity with the JS implementation, and the invalid-class error paths.

---

## 11. Known limitations and design decisions

| Area                        | Current behavior                                                                      | Rationale / next step                                                                                                                                  |
| --------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Storage**                 | `Estate_Case__c.LQC_Result__c`, via the `ILqcStorage` strategy                        | Swap by writing another implementation and naming it in `storageClass` — no LWC or controller change.                                                  |
| **Prefill classes**         | Debit/Credit/Insurance query FSC (v2.1); FixedProperties/Shares/OtherAssets are stubs | See §6.1 for the FSC inclusion rules and the DoD-balance / cover-amount TODOs.                                                                         |
| **Publish**                 | Sets `published: true` and locks the UI                                               | No approval process or audit trail, and no unpublish button by design.                                                                                 |
| **Grand total**             | Simple sum of all tab subtotals                                                       | Confirmed requirement — no tab is treated as a liability. If that changes, add a `liability: true` tab flag and subtract it in `lqcReport.grandTotal`. |
| **Currency display**        | `Intl.NumberFormat` with the **viewer's** locale                                      | An `en-ZA` user sees `R10 563 000`; an `en-US` user sees `ZAR 10,563,000`. Hardcode the locale in `lqcReport.formatter` if you need one fixed format.  |
| **Column widths**           | `%` converted against a fixed 1200 px baseline                                        | `lightning-datatable` accepts pixels only. Widths are initial values; users can drag to resize.                                                        |
| **`initialRows`**           | Applied once, on first assignment                                                     | A guard in `lqcGrid` stops a container re-render from clobbering in-progress user edits.                                                               |
| **Concurrency**             | Last write wins                                                                       | Two users on the same Case overwrite each other. Add a version check in `saveResult` if that matters.                                                  |
| **Payload `version`**       | Still `1`                                                                             | The stored shape did not change between LQC v1 and v2. Bump it if you change the shape, and branch on it in `liquidityCalculator.load()`.              |
| **Sorting / volume**        | Client-side, over all loaded rows                                                     | There is no pagination; every row for a Case is held in memory.                                                                                        |
| **Inline picklist editing** | Uses datatable custom-type `editTemplate`                                             | Requires API 59.0+ (this project is on 66.0). Jest cannot exercise real inline editing — verify by clicking in the org.                                |
