/**
 * LWC entry points. apply() runs the engine for one document; preview()
 * is the same pipeline with no DML, returning the planned old → new
 * changes for the review UI to show before Save; applyAsync() enqueues the
 * same work on a fresh transaction for a document apply() deferred (the
 * results go to the finding handler, not the caller); previewValue() lets
 * an admin test a value type's configuration against sample text without
 * deploying anything or touching a record.
 *
 * @group IDP Processing
 * @author Ernesto S Melgin
 */
public with sharing class IdpMappingController {
  /**
   * Applies a mapping set to one reviewed document.
   *
   * @param contentDocumentId Reviewed file the run is seeded from.
   * @param jsonString The reviewed JSON payload.
   * @param mappingSetName DeveloperName of the mapping set to apply.
   * @param mode Extraction, Compliance or Preview; a rule's own Mode wins.
   * @param findingHandler Optional handler overriding the set's default.
   * @return Result of the single document, including its findings.
   * @throws AuraHandledException When the run cannot be completed.
   */
  @AuraEnabled
  public static IdpResult.Result apply(
    Id contentDocumentId,
    String jsonString,
    String mappingSetName,
    String mode,
    String findingHandler
  ) {
    try {
      return runOne(
        contentDocumentId,
        jsonString,
        mappingSetName,
        mode,
        findingHandler
      );
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /**
   * Replays the pipeline without DML so the UI can show planned changes.
   *
   * @param contentDocumentId Reviewed file the run is seeded from.
   * @param jsonString The reviewed JSON payload.
   * @param mappingSetName DeveloperName of the mapping set to apply.
   * @return Result carrying the old to new changes Save would write.
   * @throws AuraHandledException When the run cannot be completed.
   */
  @AuraEnabled
  public static IdpResult.Result preview(
    Id contentDocumentId,
    String jsonString,
    String mappingSetName
  ) {
    try {
      return runOne(
        contentDocumentId,
        jsonString,
        mappingSetName,
        IdpMappingEngine.MODE_PREVIEW,
        null
      );
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /**
   * Re-runs a deferred document as a Queueable (ENG-4).
   *
   * The document gets a fresh set of governor limits and its results are
   * delivered through the finding handler. Preview is refused, because its
   * entire output is the plan this method cannot return.
   *
   * @param contentDocumentId Reviewed file the run is seeded from.
   * @param jsonString The reviewed JSON payload.
   * @param mappingSetName DeveloperName of the mapping set to apply.
   * @param mode Extraction or Compliance; Preview is rejected.
   * @param findingHandler Optional handler overriding the set's default.
   * @return Id of the enqueued job.
   * @throws AuraHandledException When Preview is requested, the mapping set
   *         is not active, or the job cannot be enqueued.
   */
  @AuraEnabled
  public static Id applyAsync(
    Id contentDocumentId,
    String jsonString,
    String mappingSetName,
    String mode,
    String findingHandler
  ) {
    try {
      if (
        String.isNotBlank(mode) &&
        (mode.trim().equalsIgnoreCase(IdpMappingEngine.MODE_PREVIEW) ||
        mode.trim().equalsIgnoreCase('Dry Run'))
      ) {
        throw new AuraHandledException(
          'Preview cannot run asynchronously — its output is the returned ' +
          'plan. Use preview() instead.'
        );
      }
      if (!IdpConfigLoader.load(mappingSetName).found) {
        throw new AuraHandledException(
          'No active IDP Mapping Set named "' + mappingSetName + '" was found.'
        );
      }
      IdpAsyncProcessor.DocumentInput document = new IdpAsyncProcessor.DocumentInput();
      document.contentDocumentId = contentDocumentId;
      document.jsonString = jsonString;
      return IdpAsyncProcessor.enqueue(
        new List<IdpAsyncProcessor.DocumentInput>{ document },
        mappingSetName,
        mode,
        findingHandler
      );
    } catch (AuraHandledException e) {
      throw e;
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /** Outcome of parsing sample text through a value type configuration. */
  public class ValuePreview {
    /** Canonical value as text, null when the text did not parse. */
    @AuraEnabled
    public String value;

    /** Parse grade label, such as Exact or Inferred. */
    @AuraEnabled
    public String grade;

    /** Explanation the value type attached to the parse. */
    @AuraEnabled
    public String note;

    /** Canonical value formatted through the type's output format. */
    @AuraEnabled
    public String rendered;
  }

  /**
   * Tries a value type's configuration against sample text.
   *
   * Lets an admin see the canonical value, the grade and the rendered
   * output without deploying anything or touching a record.
   *
   * @param valueTypeName DeveloperName of the IDP_Value_Type__mdt to use.
   * @param rawText Sample document text to parse.
   * @return Parse outcome with value, grade, note and rendered output.
   * @throws AuraHandledException When the value type is unknown or its
   *         implementation cannot be resolved.
   */
  @AuraEnabled
  public static ValuePreview previewValue(
    String valueTypeName,
    String rawText
  ) {
    try {
      IdpValueTypes.Config cfg = IdpConfigLoader.loadValueType(valueTypeName);
      if (cfg == null) {
        throw new AuraHandledException(
          'No IDP Value Type named "' + valueTypeName + '" was found.'
        );
      }
      IValueType type = IdpTypeRegistry.resolve(cfg);
      IdpValueTypes.ParseResult parsed = type.parse(rawText, cfg);
      ValuePreview result = new ValuePreview();
      result.grade = IdpResult.label(parsed.grade);
      result.note = parsed.note;
      if (parsed.value != null) {
        result.value = String.valueOf(parsed.value);
        result.rendered = type.render(parsed.value, cfg);
      }
      return result;
    } catch (AuraHandledException e) {
      throw e;
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /**
   * The full Extraction pipeline, DML skipped, against a definition that
   * has not been saved.
   *
   * Seeded from a record rather than a file: the builder is editing
   * configuration, not processing a document, and what it needs to show
   * is which records the wiring would reach and what each rule would
   * write. The sample document supplies the readings.
   *
   * Custom handlers do not run in Preview — they are arbitrary Apex with
   * side effects — and the result says which rules were skipped for that
   * reason, so the preview is honest about being incomplete.
   *
   * @param mappingSetName Name the draft definition is previewed under.
   * @param definition Unsaved mapping set definition to evaluate.
   * @param jsonString Sample document supplying the readings.
   * @param seedRecordId Record the wiring is resolved from.
   * @return Result listing the records reached and the planned writes.
   * @throws AuraHandledException When the draft cannot be evaluated.
   */
  @AuraEnabled
  public static IdpResult.Result previewDraft(
    String mappingSetName,
    String definition,
    String jsonString,
    Id seedRecordId
  ) {
    try {
      IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
      work.seedRecordId = seedRecordId;
      work.jsonString = jsonString;
      return IdpMappingEngine.run(
        new List<IdpMappingEngine.DocumentWork>{ work },
        IdpConfigLoader.loadDraft(mappingSetName, definition),
        IdpMappingEngine.MODE_PREVIEW,
        null
      )[0];
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  /**
   * Drives the bulk engine with a single document.
   *
   * @param contentDocumentId Reviewed file the run is seeded from.
   * @param jsonString The reviewed JSON payload.
   * @param mappingSetName DeveloperName of the mapping set to apply.
   * @param mode Extraction, Compliance or Preview.
   * @param findingHandler Optional handler overriding the set's default.
   * @return Result of the only document in the run.
   */
  private static IdpResult.Result runOne(
    Id contentDocumentId,
    String jsonString,
    String mappingSetName,
    String mode,
    String findingHandler
  ) {
    IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
    work.contentDocumentId = contentDocumentId;
    work.jsonString = jsonString;
    return IdpMappingEngine.run(
      new List<IdpMappingEngine.DocumentWork>{ work },
      mappingSetName,
      mode,
      findingHandler
    )[0];
  }
}
