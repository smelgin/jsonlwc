/**
 * LWC entry points. apply() runs the engine for one document; preview()
 * is the same pipeline with no DML, returning the planned old → new
 * changes for the review UI to show before Save; previewValue() lets an
 * admin test a value type's configuration against sample text without
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
