/**
 * Reprocesses stored documents without a user in the loop. The mapping
 * set's JSON_Source_Field__c names the long-text field holding the raw
 * extracted JSON, qualified as Object.Field (e.g.
 * Document__c.Extracted_JSON__c); the batch iterates that object's
 * records, seeds the engine from each record (seedRecordId — no file
 * needed) and lets the engine's bulk pipeline do the rest. Each execute()
 * chunk is one engine run.
 *
 *   Database.executeBatch(new IdpBatchProcessor('Consolidated_Statement'), 10);
 *
 * Idempotency: when the mapping set names a Processed_Marker_Field__c (a
 * Datetime field on the same object), the batch only picks up records
 * where that field is blank and stamps it after processing — successfully
 * or with errors, since both are attempts whose findings went to the
 * handler. Rerunning the batch then never redoes finished work. Documents
 * the limits guard deferred are NOT stamped, and finish() chains one
 * retry pass for them (up to MAX_RETRIES), so a transient shortfall heals
 * itself instead of silently dropping documents. To force a full rerun —
 * after a rule change, say — pass reprocessAll = true, or clear the
 * marker on the records you want redone.
 *
 * An optional scope SOQL overrides the default query (it must select the
 * JSON source field). Aggregate counts are logged from finish(); per-chunk
 * mismatch handling goes through the usual finding handler.
 *
 * @group IDP Processing
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpBatchProcessor implements Database.Batchable<SObject>, Database.Stateful {
  /** Raised when the mapping set's batch configuration is unusable. */
  public class BatchException extends Exception {
  }

  /** Chained retry passes granted to documents the limits guard defers. */
  private static final Integer MAX_RETRIES = 2;

  /** DeveloperName of the mapping set being reprocessed. */
  private final String mappingSetName;

  /** Run mode passed through to the engine. */
  private final String mode;

  /** Finding handler override, null to use the mapping set's default. */
  private final String findingHandler;

  /** Caller-supplied scope query replacing the derived one. */
  private final String scopeSoql;

  /** Whether already-stamped records are picked up again. */
  private final Boolean reprocessAll;

  /** Retry passes still available to deferred documents. */
  private final Integer retriesRemaining;

  /** Documents the engine returned a result for. */
  private Integer documentsProcessed = 0;

  /** Documents whose result reported an error. */
  private Integer documentsFailed = 0;

  /** Documents the limits guard held back for a later pass. */
  private Integer documentsDeferred = 0;

  /** Fields written across every chunk. */
  private Integer fieldsApplied = 0;

  /** Value mismatches reported across every chunk. */
  private Integer mismatches = 0;

  /**
   * Reprocesses a mapping set with its configured defaults.
   *
   * @param mappingSetName DeveloperName of the mapping set to apply.
   */
  public IdpBatchProcessor(String mappingSetName) {
    this(mappingSetName, null, null, null, false);
  }

  /**
   * Reprocesses a mapping set over an optional custom scope.
   *
   * @param mappingSetName DeveloperName of the mapping set to apply.
   * @param mode Extraction or Compliance; null takes the set's default.
   * @param findingHandler Optional handler overriding the set's default.
   * @param scopeSoql Query replacing the derived one; it must select the
   *        JSON source field.
   */
  public IdpBatchProcessor(
    String mappingSetName,
    String mode,
    String findingHandler,
    String scopeSoql
  ) {
    this(mappingSetName, mode, findingHandler, scopeSoql, false);
  }

  /**
   * Reprocesses a mapping set, optionally ignoring the processed marker.
   *
   * @param mappingSetName DeveloperName of the mapping set to apply.
   * @param mode Extraction or Compliance; null takes the set's default.
   * @param findingHandler Optional handler overriding the set's default.
   * @param scopeSoql Query replacing the derived one; it must select the
   *        JSON source field.
   * @param reprocessAll True to redo records already stamped as processed.
   */
  public IdpBatchProcessor(
    String mappingSetName,
    String mode,
    String findingHandler,
    String scopeSoql,
    Boolean reprocessAll
  ) {
    this(
      mappingSetName,
      mode,
      findingHandler,
      scopeSoql,
      reprocessAll,
      MAX_RETRIES
    );
  }

  /**
   * Creates a chained pass that carries the remaining retry allowance.
   *
   * @param mappingSetName DeveloperName of the mapping set to apply.
   * @param mode Extraction or Compliance; null takes the set's default.
   * @param findingHandler Optional handler overriding the set's default.
   * @param scopeSoql Query replacing the derived one.
   * @param reprocessAll True to redo records already stamped as processed.
   * @param retriesRemaining Retry passes left before deferrals are dropped.
   */
  private IdpBatchProcessor(
    String mappingSetName,
    String mode,
    String findingHandler,
    String scopeSoql,
    Boolean reprocessAll,
    Integer retriesRemaining
  ) {
    this.mappingSetName = mappingSetName;
    this.mode = mode;
    this.findingHandler = findingHandler;
    this.scopeSoql = scopeSoql;
    this.reprocessAll = reprocessAll == true;
    this.retriesRemaining = retriesRemaining;
  }

  /**
   * Selects the stored documents this run will reprocess.
   *
   * Validates the mapping set's batch configuration before building the
   * query, so a misconfigured set fails at the start rather than per chunk.
   *
   * @param context Batch context supplied by the platform.
   * @return Locator over the source object's records.
   * @throws BatchException When the JSON source or marker field is missing
   *         or of the wrong type.
   */
  public Database.QueryLocator start(Database.BatchableContext context) {
    String fieldName = sourceFieldName(); // validates the config
    String markerField = markerFieldName(); // validated too, null when unset
    if (String.isNotBlank(scopeSoql)) {
      return Database.getQueryLocator(scopeSoql);
    }
    // Long text areas (the natural type for stored JSON) cannot be
    // filtered in SOQL, so blanks are skipped in execute(); the Datetime
    // marker CAN be filtered, which is what makes reruns cheap.
    String soql = 'SELECT Id, ' + fieldName;
    if (markerField != null) {
      soql += ', ' + markerField;
    }
    soql += ' FROM ' + sourceObjectName();
    if (markerField != null && !reprocessAll) {
      soql += ' WHERE ' + markerField + ' = null';
    }
    return Database.getQueryLocator(soql + ' WITH USER_MODE');
  }

  /**
   * Runs one chunk as a single engine run and stamps what it finished.
   *
   * Records without stored JSON are skipped, and deferred documents are
   * left unstamped so a later pass picks exactly them up.
   *
   * @param context Batch context supplied by the platform.
   * @param scope Source records in this chunk.
   * @throws BatchException When the mapping set's batch configuration is
   *         no longer valid.
   */
  public void execute(Database.BatchableContext context, List<SObject> scope) {
    String fieldName = sourceFieldName();
    String markerField = markerFieldName();
    List<IdpMappingEngine.DocumentWork> works = new List<IdpMappingEngine.DocumentWork>();
    for (SObject record : scope) {
      String jsonString = (String) record.get(fieldName);
      if (String.isBlank(jsonString)) {
        continue; // no stored JSON — nothing to reprocess
      }
      IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
      work.seedRecordId = record.Id;
      work.jsonString = jsonString;
      works.add(work);
    }
    if (works.isEmpty()) {
      return;
    }

    List<SObject> stamps = new List<SObject>();
    Schema.SObjectType sourceType = IdpSchemaCache.typeOf(sourceObjectName());
    Datetime processedAt = Datetime.now();
    for (
      IdpResult.Result result : IdpMappingEngine.run(
        works,
        mappingSetName,
        mode,
        findingHandler
      )
    ) {
      documentsProcessed++;
      if (result.deferred == true) {
        // Not stamped — the next run (or the retry pass) picks it up.
        documentsDeferred++;
        continue;
      }
      if (result.success == false) {
        documentsFailed++;
      }
      fieldsApplied += result.fieldsApplied;
      mismatches += result.findingsWith(IdpResult.CODE_VALUE_MISMATCH).size();
      if (markerField != null && result.seedRecordId != null) {
        SObject stamp = sourceType.newSObject(Id.valueOf(result.seedRecordId));
        stamp.put(markerField, processedAt);
        stamps.add(stamp);
      }
    }
    if (!stamps.isEmpty()) {
      Database.update(stamps, false);
    }
  }

  /**
   * Logs the run's aggregate counts and chains a retry pass if needed.
   *
   * The chain only fires when a processed marker is configured; without one
   * a rerun would redo every record rather than just the deferrals.
   *
   * @param context Batch context supplied by the platform.
   */
  public void finish(Database.BatchableContext context) {
    System.debug(
      LoggingLevel.INFO,
      'IdpBatchProcessor(' +
        mappingSetName +
        '): ' +
        documentsProcessed +
        ' document(s) processed, ' +
        documentsFailed +
        ' with errors, ' +
        documentsDeferred +
        ' deferred, ' +
        fieldsApplied +
        ' field(s) applied, ' +
        mismatches +
        ' mismatch(es).'
    );
    // Deferred documents were never stamped; a retry pass picks exactly
    // them up. Without a marker a rerun would redo everything, so the
    // chain only fires when idempotency is configured.
    if (
      documentsDeferred > 0 &&
      retriesRemaining > 0 &&
      markerFieldName() != null &&
      String.isBlank(scopeSoql) &&
      !Test.isRunningTest()
    ) {
      Database.executeBatch(
        new IdpBatchProcessor(
          mappingSetName,
          mode,
          findingHandler,
          null,
          false,
          retriesRemaining - 1
        ),
        10
      );
    }
  }

  /**
   * Names the object whose records hold the stored JSON.
   *
   * @return API name of the source object.
   * @throws BatchException When the JSON source field is unusable.
   */
  private String sourceObjectName() {
    return qualifiedSourceField().substringBefore('.');
  }

  /**
   * Names the long-text field holding the stored JSON.
   *
   * @return API name of the source field.
   * @throws BatchException When the JSON source field is unusable.
   */
  private String sourceFieldName() {
    return qualifiedSourceField().substringAfter('.');
  }

  /**
   * Resolves the idempotency marker the batch stamps after processing.
   *
   * @return API name of Processed_Marker_Field__c, or null when the
   *         mapping set does not use one.
   * @throws BatchException When the configured marker is not an updateable
   *         Datetime field on the source object.
   */
  private String markerFieldName() {
    IdpConfigLoader.SetConfig config = IdpConfigLoader.load(mappingSetName);
    String markerField = config.processedMarkerField;
    if (String.isBlank(markerField)) {
      return null;
    }
    Schema.SObjectField field = IdpSchemaCache.field(
      sourceObjectName(),
      markerField
    );
    if (
      field == null ||
      field.getDescribe().getType() != Schema.DisplayType.DATETIME ||
      !field.getDescribe().isUpdateable()
    ) {
      throw new BatchException(
        'Processed Marker Field ' +
          sourceObjectName() +
          '.' +
          markerField +
          ' must be an updateable Datetime field.'
      );
    }
    return field.getDescribe().getName();
  }

  /**
   * Resolves and validates the mapping set's JSON source field.
   *
   * @return JSON_Source_Field__c as a readable Object.Field pair.
   * @throws BatchException When the mapping set is inactive or missing, the
   *         field is not qualified, or it is absent or unreadable.
   */
  private String qualifiedSourceField() {
    IdpConfigLoader.SetConfig config = IdpConfigLoader.load(mappingSetName);
    if (!config.found) {
      throw new BatchException(
        'No active IDP Mapping Set named "' + mappingSetName + '" was found.'
      );
    }
    String qualified = config.jsonSourceField;
    if (String.isBlank(qualified) || !qualified.contains('.')) {
      throw new BatchException(
        'Mapping set ' +
          mappingSetName +
          ' has no JSON Source Field (Object.Field), so it cannot run in batch.'
      );
    }
    String objectName = qualified.substringBefore('.');
    String fieldName = qualified.substringAfter('.');
    Schema.SObjectField field = IdpSchemaCache.field(objectName, fieldName);
    if (field == null || !field.getDescribe().isAccessible()) {
      throw new BatchException(
        'JSON Source Field ' + qualified + ' does not exist or is not readable.'
      );
    }
    return qualified;
  }
}
