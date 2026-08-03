/**
 * Contract for LQC tab prefill providers.
 * Implementations are instantiated dynamically by LqcController.refreshRows
 * using the class name configured in LQC_Config__mdt (tabs[N].refreshClass).
 *
 * Each returned row is a map of columnKey => value, where columnKey is the
 * camelCase key derived from the column label (see LqcController.fieldKey).
 * For textLink columns, an additional "<columnKey>RecordId" entry may be
 * provided so the UI can render a link to that record.
 */
public interface ILqcPrefill {
    List<Map<String, Object>> refresh(Id recordId);
}
