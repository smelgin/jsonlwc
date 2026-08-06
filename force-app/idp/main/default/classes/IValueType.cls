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
 */
public interface IValueType {
  IdpValueTypes.ParseResult parse(Object raw, IdpValueTypes.Config cfg);

  Object canonical(Object value, IdpValueTypes.Config cfg);

  IdpResult.CompareOutcome compare(
    Object extracted,
    Object stored,
    IdpValueTypes.Config cfg
  );

  String render(Object canonicalValue, IdpValueTypes.Config cfg);
}
