/**
 * LWC entry points. apply() runs the engine for one document; preview()
 * is the same pipeline with no DML, returning the planned old → new
 * changes for the review UI to show before Save; applyAsync() enqueues the
 * same work on a fresh transaction for a document apply() deferred (the
 * results go to the finding handler, not the caller); previewValue() lets
 * an admin test a value type's configuration against sample text without
 * deploying anything or touching a record.
 */
public with sharing class IdpMappingController {
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
   * ENG-4: the answer to a deferred apply(). Runs the same document as a
   * Queueable with a fresh set of governor limits and returns the job Id.
   * Results are delivered through the finding handler — Preview is
   * refused, because its entire output is the plan this method cannot
   * return.
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

  public class ValuePreview {
    @AuraEnabled
    public String value;

    @AuraEnabled
    public String grade;

    @AuraEnabled
    public String note;

    @AuraEnabled
    public String rendered;
  }

  /** Parses rawText through the named IDP_Value_Type__mdt and reports the
   *  canonical value, the grade and the rendered output. */
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
