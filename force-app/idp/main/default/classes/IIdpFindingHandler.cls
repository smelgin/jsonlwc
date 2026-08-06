/**
 * Contract for custom reactions to a run's findings — the v2
 * generalization of v1's IComplianceMismatchHandler. The engine invokes
 * the handler (resolved by class name with Type.forName) after a run that
 * produced compliance mismatches; the report carries every document's
 * full Result, so a handler can also react to Near matches, errors or
 * unmatched rows.
 *
 * Handlers run inside the engine's transaction. A handler that throws is
 * reported as a HANDLER_FAILED finding without rolling back extraction
 * updates from the same run.
 */
public interface IIdpFindingHandler {
  void handle(IdpResult.RunReport report);
}
