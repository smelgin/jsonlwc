/**
 * Per-rule custom handling: a rule with Mode = Custom names an
 * implementation of this interface in its handlerClass key, and the engine
 * hands it the parsed field instead of writing or comparing it — the third
 * bucket next to Extraction and Compliance.
 *
 * The handler mutates context.record in memory; the engine diffs the record
 * afterwards and stages what changed, so the run's single-update DML and
 * FLS stripping still hold. Handlers do not run in Preview (custom Apex may
 * have side effects); the preview reports which rules were skipped so the
 * planned changes are honest about being incomplete.
 *
 * Invoked once per field per record. A handler that queries should cache
 * per transaction — a SOQL inside handle() scales with row count, which is
 * exactly the cost model the engine exists to avoid. A thrown exception
 * becomes a HANDLER_FAILED finding on the document; the rest of the run
 * continues.
 *
 * Same DI convention as IIdpFindingHandler: resolved by name with
 * Type.forName at config load time, so a typo is a config finding, not a
 * runtime surprise.
 *
 * @group IDP Extensibility
 * @author Ernesto S Melgin
 */
public interface IIdpFieldHandler {
  /**
   * Applies custom handling for one parsed field on one record.
   *
   * @param context Field origin, parse outcome and the record to mutate.
   */
  void handle(IdpFieldContext context);
}
