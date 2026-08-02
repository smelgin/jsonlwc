/**
 * Custom action invoked by JsonMappingService when a Compliance Check run
 * finds mismatches between the extracted JSON values and the data model.
 *
 * Implementations are resolved by class name (Type.forName) from the
 * mismatchHandler parameter — the same dependency-injection convention the
 * LQC uses for its storageClass / refreshClass. Implementations run in the
 * same transaction; throwing surfaces as an error on the Result without
 * rolling back extraction updates from the same run.
 */
public interface IComplianceMismatchHandler {
  void handle(JsonMappingService.ComplianceReport report);
}
