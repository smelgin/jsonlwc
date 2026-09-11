/**
 * Contract of an IDP value type: how one semantic kind of document value
 * (money, phone, date, ...) is parsed, canonicalized, compared and
 * rendered. Built-in implementations live in IdpValueTypes; org-specific
 * ones are Apex classes referenced from an IDP_Value_Type__mdt record with
 * Kind = Custom and resolved with Type.forName.
 *
 * The four operations are deliberately separate:
 *  - parse()     document text → canonical typed value, with a Grade that
 *                says how sure the parse is. Never guess silently: a
 *                heuristic result is INFERRED, an undecidable one AMBIGUOUS.
 *  - canonical() EITHER side (extracted or stored) → the comparable form.
 *                This is what lets Compliance compare "+27 82 123 4567"
 *                against a stored "0821234567" without a false mismatch.
 *  - compare()   three-state verdict: MATCH, NEAR (within the configured
 *                tolerance — worth a human glance), MISMATCH.
 *  - render()    canonical value → the text written into text targets and
 *                shown in findings, per Output_Format__c.
 *
 * Implementations must be stateless: one instance serves all rules.
 *
 * @group IDP Extensibility
 * @author Ernesto S Melgin
 */
public interface IValueType {
  /**
   * Turns document text into a canonical typed value.
   *
   * @param raw Value as the document carried it, envelopes already unwrapped.
   * @param cfg Value type configuration driving parse behaviour.
   * @return Parsed value together with the Grade earned by the parse.
   */
  IdpValueTypes.ParseResult parse(Object raw, IdpValueTypes.Config cfg);

  /**
   * Reduces either side of a comparison to its comparable form.
   *
   * @param value Extracted or stored value to canonicalize.
   * @param cfg Value type configuration driving canonicalization.
   * @return Canonical form, comparable across document and record spelling.
   */
  Object canonical(Object value, IdpValueTypes.Config cfg);

  /**
   * Weighs a document value against the value already stored on the record.
   *
   * @param extracted Canonical value taken from the document.
   * @param stored Canonical value read from the target field.
   * @param cfg Value type configuration, including the NEAR tolerance.
   * @return MATCH, NEAR or MISMATCH verdict.
   */
  IdpResult.CompareOutcome compare(
    Object extracted,
    Object stored,
    IdpValueTypes.Config cfg
  );

  /**
   * Formats a canonical value for text targets and findings.
   *
   * @param canonicalValue Value already reduced to canonical form.
   * @param cfg Value type configuration supplying the output format.
   * @return Text written to the target field and surfaced in findings.
   */
  String render(Object canonicalValue, IdpValueTypes.Config cfg);
}
