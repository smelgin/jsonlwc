/**
 * Pluggable persistence strategy for the Liquidity Calculator payload.
 *
 * Implementations are instantiated dynamically by LqcController using the class
 * name configured in the JSON config ("storageClass"), exactly like the
 * ILqcPrefill refresh providers. This keeps the LWC and the controller unaware
 * of WHERE the result lives: a field on a related record, a generic payload
 * object, a file, an external system - swapping it is a metadata change.
 *
 * Contract:
 *  - load(recordId) returns the stored JSON payload, or null when nothing has
 *    been saved yet. It must not throw for "no data".
 *  - save(recordId, payload) persists the JSON, creating the destination record
 *    if the strategy needs one.
 *  - recordId is always the Id of the record the component is placed on (the
 *    Case), never the Id of the destination record. Resolving one from the
 *    other is the implementation's job.
 *  - Implementations must be public with a no-argument constructor, and are
 *    responsible for enforcing FLS/sharing (use AccessLevel.USER_MODE).
 */
public interface ILqcStorage {
    String load(Id recordId);
    void save(Id recordId, String payload);
}
