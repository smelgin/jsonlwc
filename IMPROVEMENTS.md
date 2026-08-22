# IDP Engine — Performance & Simplicity Improvements

QA / senior-dev review of `force-app/idp/main/default`, 2026-08-22.
Scope: all `Idp*` Apex classes (changes proposed here) plus the LWCs
(`jsonForm`, `idpConfigurator`, `fileJsonReview` — analysis only, changes
listed as future work in section C).

**Overall verdict:** the engine is architecturally sound — bulk-first
orchestration, transaction-scoped describe/config caches, bind variables
everywhere, `USER_MODE` queries, FLS stripping, and config errors surfaced
as findings instead of exceptions. Nothing below is structural; every item
is a targeted optimization or simplification.

**Baseline:** all 127 `Idp*`/`FilePreviewController` tests pass in
`esmelgin@brave-moose-dvc50h.com` (run `707WU00001FWeZb`, 2026-08-22).
After executing any item, re-run:

```bash
sf apex run test --tests IdpMappingEngineTest --tests IdpConfigLoaderTest --tests IdpValueTypesTest --tests IdpContextResolverTest --tests IdpFilterBinderTest --tests IdpJsonReaderTest --tests IdpBatchProcessorTest --tests IdpLocaleDataTest --tests IdpConfiguratorControllerTest --tests FilePreviewControllerTest --result-format human --wait 15
```

Run Prettier on every touched file (the repo pins a Prettier config):

```bash
npx prettier --write "force-app/idp/main/default/classes/*.cls"
```

Legend: 🔴 highest value · 🟡 worthwhile · ⚪ optional polish.
Status of every item: **Proposed** (no code has been changed yet).

---

## A. Performance

### A1. 🔴 Hoist per-call `Pattern.compile` to static finals — `IdpValueTypes.cls`

Apex `Pattern.compile` is expensive and these run once **per value parsed**,
so a batch over thousands of rows pays the compile cost thousands of times.

| Location | Pattern compiled per call |
|---|---|
| `NumberType.parse` (~line 320) | `'([A-Za-z]+)\\s*$'` (DR/CR suffix) |
| `detectCurrency` (~line 530) | `'(?<![A-Za-z])([A-Za-z]{3})(?![A-Za-z])'` (ISO code) |
| `detectCurrency` (~line 543) | `'(^|[^A-Za-z])' + escapeRegex(symbol) + '([^A-Za-z]|$)'` — rebuilt for each alphabetic symbol on each call |
| `DatetimeType.parse` (~line 1013) | `Pattern.matches('.*([+-]\\d{2}:?\\d{2}|Z)$', text)` — `Pattern.matches` compiles every call |
| `DatetimeType.parse` (~line 1019) | naive-timestamp regex |

**Instructions**

1. Add class-level constants to `IdpValueTypes`:
   ```apex
   private static final Pattern TRAILING_LETTERS = Pattern.compile('([A-Za-z]+)\\s*$');
   private static final Pattern ISO_CODE_TOKEN =
     Pattern.compile('(?<![A-Za-z])([A-Za-z]{3})(?![A-Za-z])');
   private static final Pattern OFFSET_SUFFIX =
     Pattern.compile('.*([+-]\\d{2}:?\\d{2}|Z)$');
   private static final Pattern NAIVE_TIMESTAMP = Pattern.compile(
     '^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2})(?::(\\d{2}))?$');
   ```
2. Replace each inline `Pattern.compile(...)` / `Pattern.matches(...)` with
   `CONSTANT.matcher(text)` (`.matches()` / `.find()` as before).
3. For the per-symbol boundary patterns, build once lazily:
   ```apex
   private static Map<String, Pattern> symbolPatterns;
   ```
   populated on first `detectCurrency` call from `SYMBOL_ORDER` (only the
   alphabetic symbols and `R$` need a compiled boundary pattern; the rest
   stay simple `contains` checks as today).

Behavior-preserving. Verify with `IdpValueTypesTest` (currency, number and
datetime methods all exercise these paths).

### A2. 🔴 Stop re-describing hub fields per document — `IdpContextResolver.cls`

`expandHubs` (~lines 199–237) loops `hubFields.values()` **inside** the
per-document loop, calling `field.getDescribe()` (and `getReferenceTo()[0]
.getDescribe()`) for every hub field × every document. With a 200-field
`Document__c` and a 50-doc batch chunk that is ~10,000 describe calls per
run for information that never changes within the transaction.

**Instructions**

1. Before the `for (DocContext doc : docs)` loop, compute the hub's
   reference fields once:
   ```apex
   // field API name -> parent object API name
   Map<String, String> hubLookups = new Map<String, String>();
   for (Schema.SObjectField field : hubFields.values()) {
     Schema.DescribeFieldResult d = field.getDescribe();
     if (d.getType() == Schema.DisplayType.REFERENCE &&
         !d.getReferenceTo().isEmpty()) {
       String parentType = d.getReferenceTo()[0].getDescribe().getName();
       if (!SKIPPED_PARENT_TYPES.contains(parentType)) {
         hubLookups.put(d.getName(), parentType);
       }
     }
   }
   ```
2. In the per-doc loop, iterate `hubLookups` instead of `hubFields.values()`
   and drop the inline describe/skip logic.

Same shape applies (smaller win) to `selectList` (~lines 534–581), which
runs once per query rather than per doc — acceptable as-is; optional.

Behavior-preserving. Verify with `IdpContextResolverTest`.

### A3. 🟡 Cache `DescribeFieldResult` in `IdpSchemaCache`

Callers throughout the engine hold a `Schema.SObjectField` token and call
`.getDescribe()` repeatedly on it (e.g. `IdpMappingEngine.matchAndApplyGroup`
calls it twice per rule per group; `IdpRuleEvaluator.apply` once per rule per
record). Each call re-creates a describe result.

**Instructions**

1. Add to `IdpSchemaCache`:
   ```apex
   private static Map<String, Schema.DescribeFieldResult> fieldDescribes =
     new Map<String, Schema.DescribeFieldResult>();

   /** Cached field describe; null when object or field does not exist. */
   public static Schema.DescribeFieldResult fieldDescribe(
     String objectName, String fieldName
   ) {
     String key = keyOf(objectName) + '.' + keyOf(fieldName);
     if (!fieldDescribes.containsKey(key)) {
       Schema.SObjectField token = field(objectName, fieldName);
       fieldDescribes.put(key, token == null ? null : token.getDescribe());
     }
     return fieldDescribes.get(key);
   }
   ```
2. Migrate hot-path callers (`IdpRuleEvaluator.apply`,
   `IdpMappingEngine.matchAndApplyGroup`/`collectRows`,
   `IdpConfigLoader.assembleRule`) to `fieldDescribe(...)` where they
   currently do `IdpSchemaCache.field(...).getDescribe()` or hold the token
   only to describe it.

Behavior-preserving. Verify with the full baseline suite.

### A4. 🟡 Replace O(n²) string building — `IdpValueTypes.cls`, `IdpLocaleData.cls`

Apex strings are immutable; `+=` in a loop is quadratic. Affected:

- `IdpValueTypes.escapeRegex` (~line 558) — called per symbol per parse and
  from the date-pattern compiler.
- `IdpValueTypes.compileDatePattern` (~line 873) and `formatDate`
  (~line 944) — `regex += …` / `output += …` per token.
- `IdpLocaleData.fold` (~line 264) — `folded += …` per character (already
  short-circuits for plain ASCII, so lowest priority here).

**Instructions:** accumulate into a `List<String>` and finish with
`String.join(parts, '')`. Purely mechanical; behavior identical.

### A5. ⚪ Skip the redundant `compliant` recomputation — `IdpMappingEngine.run`

Lines 166–169:

```apex
for (IdpResult.Result result : results) {
  result.compliant = result.findingsWith(IdpResult.CODE_VALUE_MISMATCH).isEmpty();
}
```

`IdpResult.Result.add()` already sets `compliant = false` whenever a
`VALUE_MISMATCH` finding is added, and `compliant` initializes `true`, so
this loop re-derives a value that is always already correct — at O(total
findings) per document. **Delete the loop.** (Keep `add()`'s behavior as
the single source of truth; a comment on the field noting this is worth
adding.)

Behavior-preserving. Verify with `IdpMappingEngineTest`
(`complianceReportsMismatchAndNear`, `perRuleModeMixesExtractionAndCompliance`).

---

## B. Simplicity / maintainability (Apex)

### B1. 🟡 Deduplicate the null-safe canonical compare across value types

`TextType`, `BooleanType`, `ValueMapType` and `RegexType` all implement the
identical compare:

```apex
if (stored == null) { return MISMATCH; }
return canonical(extracted, cfg) == canonical(stored, cfg) ? MATCH : MISMATCH;
```

**Instructions:** add one static helper to `IdpValueTypes`:

```apex
private static IdpResult.CompareOutcome compareCanonical(
  IValueType type, Object extracted, Object stored, Config cfg
) {
  if (stored == null) { return IdpResult.CompareOutcome.MISMATCH; }
  return type.canonical(extracted, cfg) == type.canonical(stored, cfg)
    ? IdpResult.CompareOutcome.MATCH
    : IdpResult.CompareOutcome.MISMATCH;
}
```

and have the four `compare` methods delegate to it. (Number/Date/Datetime/
Phone keep their tolerance-aware compares.) Behavior-preserving.

### B2. ⚪ Name the query-estimate magic numbers — `IdpMappingEngine.run`

Line 119: `Integer estimate = 2 + requests.size() * 7 + config.sections.size();`
The `2` and `7` encode the cost model (link query + flush headroom; up to
~7 queries per anchored object across root fetch, hub expansion and three
passes of parent/child hops) but nothing says so.

**Instructions:** extract `private static final Integer BASE_QUERIES = 2;`
and `QUERIES_PER_ANCHOR = 7;` with a comment deriving each number from the
resolver's passes. No behavior change.

### B3. ⚪ Get-or-create map helper

The `if (!map.containsKey(k)) { map.put(k, new List<…>()); } map.get(k).add(v)`
pattern appears ~8 times (`IdpMappingEngine.processRepeatingSection`,
`IdpContextResolver.want`/`want1`/`collectRootCandidates`,
`IdpMappingInvocable.apply`, `jsonForm` equivalents). Apex generics can't
express one shared helper across value types, so this stays local: where a
class repeats it 3+ times, extract a private helper as
`IdpContextResolver.want`/`want1` already demonstrate. Cosmetic only.

### B4. ⚪ `IdpConfigLoader.load` double lookup

`cache.containsKey(key)` + `cache.get(key)` — a single
`SetConfig cached = cache.get(key); if (cached == null) { … }` reads
cleaner and saves a map probe. (Safe because `assemble` never returns
null.) Same micro-pattern exists in `IdpSchemaCache`, where it must stay:
there `null` is a legitimate cached miss.

---

## C. Behavior-changing proposal (requires sign-off — NOT to be applied with the items above)

### C1. Skip rule-less repeating sections — `IdpMappingEngine.processRepeatingSection`

`processFixedSection` early-returns when `section.rules.isEmpty()`;
`processRepeatingSection` does not, so a repeating section with zero active
rules still collects rows, renders match keys and runs its row-matching
SOQL — producing `ROW_UNMATCHED` / duplicate-key findings and `rowsMatched`
counts for a section that can map nothing.

**Proposed:** add the same `if (section.rules.isEmpty()) { return; }` guard.
**Consequence:** those findings/counts disappear for rule-less sections. If
any consumer relies on a repeating section as a pure "do these rows exist"
compliance check with no rules, this would silently change its output —
hence sign-off first. Decision on 2026-08-22: deferred.

---

## D. LWC findings (analysis only — future work)

### D1. 🔴 `jsonForm.nodeFor` walks the whole tree per keystroke — `jsonForm.js` (~line 1005)

Every `handleValueChange` / `handleLabelChange` / toggle / delete resolves
its node by walking every node in the tree (`eachNode`) — and does not even
stop at the first hit. On a large document this makes each keystroke O(n).

**Fix:** maintain a `Map` of id → node (`_nodesById`), populated in
`buildNode`/`createNode`, entries removed in `removeNode`, cleared in
`applyJson`. `nodeFor` becomes `this._nodesById.get(id)`. The component
already does exactly this for rows (`_rowsById`), so the pattern is
established.

### D2. 🟡 `jsonForm.notifyChange` serializes the tree three times per edit

`notifyChange` calls `getJson()` (serialize #1), `getJsonString()`
(serialize #2) and `this.jsonOutput` (serialize #3) on every keystroke.

**Fix:** serialize once into a local, derive the string forms from it:

```js
const value = this.getJson();
const jsonString = JSON.stringify(value, null, 3);
// detail: { value, jsonString, valid }
// FlowAttributeChangeEvent('jsonOutput', value === undefined ? '' : JSON.stringify(value))
```

### D3. 🟡 `idpConfigurator` `dirty` getter re-serializes on every render

`get dirty` calls `toJson()` (full model walk + `JSON.stringify`) plus
`sameJson` (two parses + two stringifies), and `dirty` is read by
`saveDisabled`, `revertDisabled`, `statusLabel` and `statusClass` — so up to
~4× per render cycle. Fine at current config sizes; if the configurator ever
feels sluggish, memoize `toJson()` against a model revision counter bumped
in the handlers that touch `this.model`.

### D4. ⚪ `jsonForm` search rebuilds rows per keystroke

`handleSearch` runs `computeMatches` + `rebuildRows` on every input event.
For very large documents, debounce ~150 ms. Not worth it until a real
document proves slow.

### D5. ⚪ `fileJsonReview`

No performance issues found. The PDF.js handshake (ready → base64 →
postMessage, timeout fallback) and the pointer-drag teardown are correct,
including listener cleanup in `disconnectedCallback`.

---

## Execution order

1. A5 (delete redundant loop — trivial, zero risk)
2. A1 (static patterns)
3. A2 (hub describe hoist)
4. A3 (field-describe cache)
5. A4, B1, B2, B4 (mechanical)
6. Run Prettier + full baseline test suite (must stay 127/127)
7. D1, D2 as a separate LWC change set (Jest: `npm test` covers
   `jsonForm.test.js`)
8. C1 only with explicit sign-off

Items within steps 1–5 are independent and each individually testable;
land them as one commit or several, but never mixed with C1.
