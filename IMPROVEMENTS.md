# IDP Engine — Performance & Simplicity Improvements

QA / senior-dev review of `force-app/idp/main/default`, 2026-08-22.
Scope: all `Idp*` Apex classes plus the LWCs (`jsonForm`, `idpConfigurator`,
`fileJsonReview`).

**Status: applied.** Everything in sections A, B and D below is implemented,
deployed and verified. The one behaviour-changing proposal (C1) was **not**
applied — it moved to [BACKLOG.md](BACKLOG.md) as **ENG-10**, blocked on
sign-off.

**Overall verdict:** the engine is architecturally sound — bulk-first
orchestration, transaction-scoped describe/config caches, bind variables
everywhere, `USER_MODE` queries, FLS stripping, and config errors surfaced
as findings instead of exceptions. Nothing below was structural; every item
is a targeted optimization or simplification.

## Verification

| Gate                    | Before                          | After                               |
| ----------------------- | ------------------------------- | ----------------------------------- |
| Apex tests (10 classes) | 127 pass, run `707WU00001FWeZb` | **127 pass**, run `707WU00001FbYxl` |
| Jest (`npm test`)       | 88 pass                         | **88 pass**                         |
| ESLint                  | clean                           | clean                               |
| Prettier                | clean                           | clean                               |

Every change is behaviour-preserving; the suites are unchanged from the
baseline, which is the point — these are optimizations, not new behaviour.

```bash
sf apex run test --tests IdpMappingEngineTest --tests IdpConfigLoaderTest --tests IdpValueTypesTest --tests IdpContextResolverTest --tests IdpFilterBinderTest --tests IdpJsonReaderTest --tests IdpBatchProcessorTest --tests IdpLocaleDataTest --tests IdpConfiguratorControllerTest --tests FilePreviewControllerTest --result-format human --wait 20
```

Legend: 🔴 highest value · 🟡 worthwhile · ⚪ optional polish.

---

## A. Performance — ✅ applied

### A1. 🔴 Hoist per-call `Pattern.compile` to static finals — `IdpValueTypes.cls`

Apex `Pattern.compile` is expensive and these ran once **per value parsed**,
so a batch over thousands of rows paid the compile cost thousands of times.

Compiled per call, now hoisted:

- `NumberType.parse` — the DR/CR suffix pattern → `TRAILING_LETTERS`
- `detectCurrency` — the ISO-code token pattern → `ISO_CODE_TOKEN`
- `detectCurrency` — the word-boundary pattern for each alphabetic symbol,
  string-concatenated and recompiled **per symbol per call** → built once
  into a lazy `symbolPatterns()` map
- `DatetimeType.parse` — `Pattern.matches('.*([+-]…|Z)$', text)`, which
  recompiles on every call → `OFFSET_SUFFIX`
- `DatetimeType.parse` — the naive-timestamp pattern → `NAIVE_TIMESTAMP`

The four constants are `private static final`; the symbol map stays lazy
because it depends on `SYMBOL_ORDER` and `escapeRegex`, declared later in
the file. Symbols without a boundary requirement keep the cheaper
`text.contains(symbol)` path exactly as before.

### A2. 🔴 Stop re-describing hub fields per document — `IdpContextResolver.cls`

`expandHubs` looped `hubFields.values()` **inside** the per-document loop,
calling `field.getDescribe()` and `getReferenceTo()[0].getDescribe()` for
every hub field × every document. With a 200-field `Document__c` and a
50-document batch chunk that was ~10,000 describe calls per run for
information that cannot vary within a transaction.

The hub's reference fields are now resolved once per run into a
`Map<String, String>` of lookup field API name → parent object API name,
with the `SKIPPED_PARENT_TYPES` filter applied at build time. The
per-document loop iterates that map and does no describing at all.

### A3. 🟡 Cache `DescribeFieldResult` in `IdpSchemaCache`

Each `getDescribe()` call builds a fresh result, and callers were describing
the same field repeatedly — `matchAndApplyGroup` twice per rule per group,
`IdpRuleEvaluator.apply` once per rule per record, `processRepeatingSection`
once per section.

Added `IdpSchemaCache.fieldDescribe(objectName, fieldName)`, cached for the
transaction alongside the existing object-describe and field-map caches, and
migrated the hot-path callers:

- `IdpRuleEvaluator.apply` — one call replaces a token lookup plus a describe
- `IdpMappingEngine.matchAndApplyGroup` — replaces two describes per rule
  (the local `described` field map is no longer needed)
- `IdpMappingEngine.processRepeatingSection` / `collectRows` — now carry a
  `Schema.DescribeFieldResult` rather than an `SObjectField` token they only
  ever described

### A4. 🟡 Replace O(n²) string building — `IdpValueTypes.cls`, `IdpLocaleData.cls`

Apex strings are immutable, so `+=` in a loop is quadratic. Converted to
`List<String>` accumulation finished with `String.join(parts, '')`:

- `IdpValueTypes.escapeRegex` — per character
- `IdpValueTypes.compileDatePattern` — per pattern token
- `IdpValueTypes.formatDate` — per pattern token
- `IdpLocaleData.fold` — per character (already short-circuits for plain
  ASCII, so this is the smallest of the four)

### A5. ⚪ Delete the redundant `compliant` recomputation — `IdpMappingEngine.run`

The end-of-run loop re-derived `compliant` by scanning every finding of
every document:

```apex
for (IdpResult.Result result : results) {
  result.compliant = result.findingsWith(IdpResult.CODE_VALUE_MISMATCH).isEmpty();
}
```

`IdpResult.Result.add()` already clears `compliant` the moment a
`VALUE_MISMATCH` finding is recorded, and the field initializes to `true`,
so the loop could only ever confirm what was already correct — at O(total
findings) per document, and with an allocation per document from
`findingsWith`. Deleted, with a comment naming `add()` as the single source
of truth so it does not grow back.

---

## B. Simplicity / maintainability — ✅ applied

### B1. 🟡 Deduplicate the null-safe canonical compare — `IdpValueTypes.cls`

`TextType`, `BooleanType`, `ValueMapType` and `RegexType` each carried a
byte-identical eleven-line `compare`. They now delegate to one private
`compareCanonical(type, extracted, stored, cfg)` helper; `NumberType`,
`DateType`, `DatetimeType` and `PhoneType` keep their own tolerance-aware
compares, which is the distinction the helper's doc comment records.

Net: 44 lines of duplicated logic become one helper plus four one-line
delegations.

### B2. ⚪ Name the query-estimate constants — `IdpMappingEngine.run`

`2 + requests.size() * 7 + config.sections.size()` encoded the cost model in
bare literals. Now `BASE_QUERIES` and `QUERIES_PER_ANCHOR`, each with a
comment deriving the number from what the resolver actually does (the
ContentDocumentLink query plus a spare; root fetch + hub expansion + a
parent and a child hop on each of three passes).

### B3. ⚪ Get-or-create map helper — **no change needed**

Re-checked against the criterion "3+ occurrences of the same shape in one
class". No class meets it: `IdpContextResolver` already factors the pattern
into `want`/`want1`, and its three remaining inline uses each build a
different value type (`List<Id>`, `List<DocContext>`,
`Map<Id, List<DocContext>>`) which Apex generics cannot unify into one
helper. `IdpMappingEngine` and `IdpMappingInvocable` have one occurrence
each. Recorded as considered-and-rejected rather than left ambiguous.

### B4. ⚪ Single map probe in `IdpConfigLoader.load`

`containsKey` + `get` became one `get` and a null check, safe because
`assemble` never returns null. The same double-probe in `IdpSchemaCache`
was deliberately left alone: there `null` is a legitimate cached miss, so
`containsKey` is load-bearing.

---

## C. Behaviour-changing proposal — ⛔ not applied, moved to backlog

### C1. Skip rule-less repeating sections

`processRepeatingSection` lacks the `if (section.rules.isEmpty()) return;`
guard its fixed-section counterpart has, so a repeating section with zero
active rules still collects rows, renders match keys and spends a SOQL to
map nothing.

Skipping it would also stop that section emitting `ROW_UNMATCHED` /
`ROW_DUPLICATE_KEY` findings and counting `rowsMatched` — a silent output
change for anyone using a rule-less repeating section as an existence check.

**Moved to [BACKLOG.md](BACKLOG.md) as ENG-10 (🔒 blocked on sign-off),**
with the decision to be taken written out there. Not implemented.

---

## D. LWC — ✅ applied

### D1. 🔴 `jsonForm.nodeFor` walked the whole tree per keystroke

Every value edit, label edit, collapse toggle, add and delete resolved its
node by walking every node in the tree — and did not even stop at the first
match, so each keystroke was reliably O(n).

Now indexed: `_nodesById` is populated in `buildNode` and `createNode`,
reset in `applyJson`, and `nodeFor` is a single `Map.get`. A new `forget()`
removes a deleted node **and its descendants** from the index, preserving
the invariant the old tree walk gave for free — a detached node can never
resolve by id. This mirrors the `_rowsById` index the component already
kept for rows.

### D2. 🟡 `jsonForm.notifyChange` serialized the tree three times per edit

`getJson()`, `getJsonString()` and `this.jsonOutput` each walked and
re-serialized the whole tree, on every keystroke. Now the tree is walked
once into a local and the two string forms are derived from it.

Both outputs are byte-identical to before, including the detail they differ
in: `detail.jsonString` stays indented (3 spaces) while the `jsonOutput`
Flow attribute stays compact.

### D3. 🟡 `idpConfigurator.dirty` re-serializes on every render — **not changed**

`get dirty` runs `toJson()` (full model walk + stringify) plus `sameJson`
(two parses, two stringifies), and is read by `saveDisabled`,
`revertDisabled`, `statusLabel` and `statusClass` — up to ~4× per render.
Correct, and negligible at real configuration sizes (tens of rules). The fix
if it ever matters: memoize `toJson()` against a revision counter bumped by
the handlers that mutate `this.model`. Deliberately not done — it adds
invalidation state to buy nothing measurable today.

### D4. ⚪ `jsonForm` search rebuilds rows per keystroke — **not changed**

`handleSearch` runs `computeMatches` + `rebuildRows` per input event. Worth
a ~150 ms debounce only once a real document proves slow; already tracked as
**JF-12** (virtualise long forms) in [BACKLOG.md](BACKLOG.md), which is the
better fix for the same underlying scale problem.

### D5. ⚪ `fileJsonReview` — nothing found

The PDF.js handshake (ready → base64 → postMessage, with a timeout
fallback) and the pointer-drag teardown are correct, including listener
cleanup in `disconnectedCallback`.

---

## Follow-up spotted while applying

**`ValueMapType.applyMap` compiles a regex per entry per parse.**
`Pattern.matches(entry.fromText, text)` recompiles on every call, for every
`Regex`-style entry, for every value parsed — the same defect as A1 but in a
loop. Left alone because it was not in the reviewed scope and because the
`try/catch` around it (invalid patterns are skipped, having been reported at
load time) needs its semantics preserved when the compile moves to cache
time. Worth folding into the next pass over that class.
