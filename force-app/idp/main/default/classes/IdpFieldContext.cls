/**
 * Everything a per-rule field handler (IIdpFieldHandler, a rule with Mode =
 * Custom) is given about the field it was handed: where the value came
 * from, how it parsed, and the record it may mutate. A context object
 * rather than loose arguments, so the signature survives later additions.
 *
 * The contract is "mutate record in memory": set fields on `record` and
 * return. The engine diffs the record afterwards and stages every changed
 * field through its own executor, so the run keeps its single FLS-stripped
 * update and a handler never needs (and should never perform) DML of its
 * own. On a record the run is about to create (record.Id == null) the
 * mutations ride along on the insert.
 */
public inherited sharing class IdpFieldContext {
  /** The rule's JSON Path, as configured. */
  public String jsonPath;

  /** API name of the object the rule targets. */
  public String targetObject;

  /** API name of the field the rule targets. Advisory — the handler may
   *  write any field on the record. */
  public String targetField;

  /** What the document literally said at the path (envelopes unwrapped). */
  public Object rawValue;

  /** The value after the rule's value type parsed it (Decimal, Date, ...). */
  public Object parsedValue;

  /** Parse grade label: Exact or Inferred (worse grades never reach a
   *  handler — the ordinary gates run first). */
  public String grade;

  /** OCR confidence from the JSON envelope, when the document carried one. */
  public Decimal confidence;

  /** The target record, queried fields populated. Mutate it in memory. */
  public SObject record;

  /** Section the rule belongs to. */
  public String sectionName;

  /** Row position within a repeating section; null for fixed sections. */
  public Integer rowIndex;

  /** Row match key within a repeating section; null for fixed sections. */
  public String rowKey;
}
