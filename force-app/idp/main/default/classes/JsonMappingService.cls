/**
 * Applies a set of JSON_Field_Mapping__mdt rules to the JSON produced by a
 * document review (e.g. the fileJsonReview component). Two modes:
 *
 *  - Extraction (default): writes the extracted values into the records
 *    reachable from the ContentDocument.
 *  - Compliance: writes nothing — compares each extracted value with the
 *    field's stored value and collects mismatches (a blank stored field
 *    counts as a mismatch; text compares trimmed and case-insensitively).
 *    When mismatches exist and a mismatchHandler class name is given, the
 *    class (implementing IComplianceMismatchHandler) is instantiated via
 *    Type.forName and invoked — same DI convention as the LQC storageClass.
 *
 * The run mode is a parameter; a rule's Mode__c overrides it per field, so
 * one set can extract some fields and verify others in a single call.
 *
 * Entry points:
 *  - apply()          @InvocableMethod, for Screen Flows / OmniScripts
 *  - applyMappings()  @AuraEnabled, for parent LWCs (see
 *                     fileJsonReviewMappingDemo)
 *
 * Partial success by design: rule-level problems (unreachable object,
 * unknown field, unconvertible value) are collected into Result.errors
 * while the remaining fields still process. DML uses partial success too.
 * Mismatches are data, not errors — they don't clear Result.success.
 */
public inherited sharing class JsonMappingService {
  public static final String MODE_EXTRACTION = 'Extraction';
  public static final String MODE_COMPLIANCE = 'Compliance';
  private static final String POLICY_ONLY_IF_BLANK = 'Only if blank';
  private static final String MODE_INVALID = 'INVALID';

  public class Request {
    @InvocableVariable(
      required=true
      label='Content Document Id'
      description='Id of the reviewed file (ContentDocument).'
    )
    public String contentDocumentId;

    @InvocableVariable(
      required=true
      label='JSON String'
      description='The reviewed JSON, e.g. the jsonOutput of fileJsonReview.'
    )
    public String jsonString;

    @InvocableVariable(
      required=true
      label='Mapping Set Name'
      description='Mapping_Set__c of the JSON_Field_Mapping__mdt rules to apply.'
    )
    public String mappingSetName;

    @InvocableVariable(
      label='Mode'
      description='Extraction (default) or Compliance. A rule\'s Mode__c overrides this per field.'
    )
    public String mode;

    @InvocableVariable(
      label='Mismatch Handler Class'
      description='Apex class implementing IComplianceMismatchHandler, invoked when a Compliance run finds mismatches.'
    )
    public String mismatchHandler;
  }

  public class Result {
    @InvocableVariable
    @AuraEnabled
    public Boolean success;

    @InvocableVariable
    @AuraEnabled
    public Boolean compliant;

    @InvocableVariable
    @AuraEnabled
    public Integer fieldsApplied;

    @InvocableVariable
    @AuraEnabled
    public Integer fieldsCompared;

    @InvocableVariable
    @AuraEnabled
    public List<String> updatedRecordIds;

    @InvocableVariable
    @AuraEnabled
    public List<Mismatch> mismatches;

    @InvocableVariable
    @AuraEnabled
    public List<String> errors;
  }

  public class Mismatch {
    @InvocableVariable
    @AuraEnabled
    public String objectName;

    @InvocableVariable
    @AuraEnabled
    public String recordId;

    @InvocableVariable
    @AuraEnabled
    public String fieldName;

    @InvocableVariable
    @AuraEnabled
    public String jsonPath;

    @InvocableVariable
    @AuraEnabled
    public String extractedValue;

    @InvocableVariable
    @AuraEnabled
    public String actualValue;
  }

  /** Payload handed to IComplianceMismatchHandler implementations. */
  public class ComplianceReport {
    public Id contentDocumentId;
    public String mappingSetName;
    public List<Mismatch> mismatches;
  }

  @InvocableMethod(
    label='Apply JSON Field Mappings'
    description='Extracts values from a reviewed JSON document into the Salesforce records reachable from the ContentDocument, or checks them for compliance, driven by JSON_Field_Mapping__mdt.'
  )
  public static List<Result> apply(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request request : requests) {
      results.add(
        applyOne(
          request.contentDocumentId,
          request.jsonString,
          request.mappingSetName,
          request.mode,
          request.mismatchHandler
        )
      );
    }
    return results;
  }

  @AuraEnabled
  public static Result applyMappings(
    Id contentDocumentId,
    String jsonString,
    String mappingSetName,
    String mode,
    String mismatchHandler
  ) {
    try {
      return applyOne(
        contentDocumentId,
        jsonString,
        mappingSetName,
        mode,
        mismatchHandler
      );
    } catch (Exception e) {
      throw new AuraHandledException(e.getMessage());
    }
  }

  private static Result applyOne(
    Id contentDocumentId,
    String jsonString,
    String mappingSetName,
    String mode,
    String mismatchHandlerName
  ) {
    Result result = new Result();
    result.fieldsApplied = 0;
    result.fieldsCompared = 0;
    result.updatedRecordIds = new List<String>();
    result.mismatches = new List<Mismatch>();
    result.errors = new List<String>();

    String runMode = String.isBlank(mode)
      ? MODE_EXTRACTION
      : normalizeMode(mode);
    if (runMode == MODE_INVALID) {
      result.success = false;
      result.compliant = true;
      result.errors.add(
        'Unknown mode "' +
          mode +
          '" — use "' +
          MODE_EXTRACTION +
          '" or "' +
          MODE_COMPLIANCE +
          '".'
      );
      return result;
    }

    List<JSON_Field_Mapping__mdt> rules = JsonMappingSelector.selectActive(
      mappingSetName
    );
    if (rules.isEmpty()) {
      result.success = false;
      result.compliant = true;
      result.errors.add(
        'No active JSON Field Mapping rules found for mapping set "' +
          mappingSetName +
          '".'
      );
      return result;
    }

    Object root;
    try {
      root = JSON.deserializeUntyped(jsonString);
    } catch (Exception e) {
      result.success = false;
      result.compliant = true;
      result.errors.add('The JSON could not be parsed: ' + e.getMessage());
      return result;
    }

    Map<String, SObject> anchors = DocumentContextResolver.resolve(
      contentDocumentId,
      anchorRequests(rules),
      root
    );

    // One pending update per touched object, carrying only mapped fields
    // so unrelated queried values are never written back.
    Map<String, SObject> pending = new Map<String, SObject>();
    for (JSON_Field_Mapping__mdt rule : rules) {
      String ruleMode = String.isBlank(rule.Mode__c)
        ? runMode
        : normalizeMode(rule.Mode__c);
      if (ruleMode == MODE_INVALID) {
        result.errors.add(
          'Rule ' +
            rule.JSON_Path__c +
            ' has unknown Mode__c "' +
            rule.Mode__c +
            '".'
        );
        continue;
      }
      applyRule(rule, ruleMode, root, anchors, pending, result);
    }

    if (!pending.isEmpty()) {
      saveUpdates(pending.values(), result);
    }

    result.compliant = result.mismatches.isEmpty();
    if (
      !result.mismatches.isEmpty() && String.isNotBlank(mismatchHandlerName)
    ) {
      ComplianceReport report = new ComplianceReport();
      report.contentDocumentId = contentDocumentId;
      report.mappingSetName = mappingSetName;
      report.mismatches = result.mismatches;
      invokeMismatchHandler(mismatchHandlerName, report, result);
    }

    result.success = result.errors.isEmpty();
    return result;
  }

  private static void applyRule(
    JSON_Field_Mapping__mdt rule,
    String ruleMode,
    Object root,
    Map<String, SObject> anchors,
    Map<String, SObject> pending,
    Result result
  ) {
    String objectName = rule.Target_Object__c;
    String fieldName = rule.Target_Field__c;

    SObject anchor = anchors.get(objectName);
    if (anchor == null) {
      result.errors.add(
        'No ' +
          objectName +
          ' record is reachable from this file — skipped ' +
          rule.JSON_Path__c +
          '.'
      );
      return;
    }

    Schema.SObjectField field = anchor.getSObjectType()
      .getDescribe()
      .fields.getMap()
      .get(fieldName);
    if (field == null) {
      result.errors.add('Unknown field ' + objectName + '.' + fieldName + '.');
      return;
    }

    Object raw = JsonPathReader.read(root, rule.JSON_Path__c);
    if (raw == null) {
      return; // path absent in this document — nothing to map or check
    }

    Object value;
    try {
      value = FieldValueCoercer.coerce(
        field.getDescribe(),
        raw,
        rule.Transform__c
      );
    } catch (FieldValueCoercer.CoercionException e) {
      result.errors.add(objectName + '.' + fieldName + ': ' + e.getMessage());
      return;
    }

    if (ruleMode == MODE_COMPLIANCE) {
      checkCompliance(rule, anchor, field, value, result);
      return;
    }

    if (rule.Overwrite_Policy__c == POLICY_ONLY_IF_BLANK) {
      Object current = currentValue(anchor, fieldName);
      if (current != null && String.valueOf(current) != '') {
        return;
      }
    }

    SObject target = pending.get(objectName);
    if (target == null) {
      target = anchor.getSObjectType().newSObject(anchor.Id);
      pending.put(objectName, target);
    }
    target.put(fieldName, value);
    result.fieldsApplied++;
  }

  /**
   * Compliance Check: no DML — compare the coerced extracted value with the
   * stored value and record a Mismatch when they differ. A blank stored
   * field cannot confirm the document, so it counts as a mismatch.
   */
  private static void checkCompliance(
    JSON_Field_Mapping__mdt rule,
    SObject anchor,
    Schema.SObjectField field,
    Object extracted,
    Result result
  ) {
    result.fieldsCompared++;
    Object actual = currentValue(anchor, field.getDescribe().getName());
    if (valuesMatch(extracted, actual)) {
      return;
    }
    Mismatch mismatch = new Mismatch();
    mismatch.objectName = rule.Target_Object__c;
    mismatch.recordId = anchor.Id;
    mismatch.fieldName = rule.Target_Field__c;
    mismatch.jsonPath = rule.JSON_Path__c;
    mismatch.extractedValue = String.valueOf(extracted);
    mismatch.actualValue = actual == null ? null : String.valueOf(actual);
    result.mismatches.add(mismatch);
  }

  /**
   * Type-aware equality: numbers by value regardless of Integer/Decimal
   * boxing, text trimmed / whitespace-collapsed / case-insensitive, other
   * types (Date, Datetime, Boolean) by value.
   */
  @TestVisible
  private static Boolean valuesMatch(Object extracted, Object actual) {
    if (actual == null) {
      return false;
    }
    if (isNumber(extracted) && isNumber(actual)) {
      return asDecimal(extracted) == asDecimal(actual);
    }
    if (extracted instanceof String) {
      return normalizeText((String) extracted) ==
        normalizeText(String.valueOf(actual));
    }
    return extracted == actual;
  }

  private static Boolean isNumber(Object value) {
    return value instanceof Decimal ||
      value instanceof Integer ||
      value instanceof Long ||
      value instanceof Double;
  }

  private static Decimal asDecimal(Object value) {
    return Decimal.valueOf(String.valueOf(value));
  }

  private static String normalizeText(String value) {
    return value == null
      ? ''
      : value.trim().replaceAll('\\s+', ' ').toLowerCase();
  }

  private static Object currentValue(SObject anchor, String fieldName) {
    try {
      return anchor.get(fieldName);
    } catch (Exception e) {
      return null; // not queried (e.g. FLS) — treat as blank
    }
  }

  private static void saveUpdates(List<SObject> pending, Result result) {
    SObjectAccessDecision decision = Security.stripInaccessible(
      AccessType.UPDATABLE,
      pending
    );
    for (String objectName : decision.getRemovedFields().keySet()) {
      result.errors.add(
        'No update access to ' +
          objectName +
          ' field(s): ' +
          String.join(
            new List<String>(decision.getRemovedFields().get(objectName)),
            ', '
          ) +
          '.'
      );
    }
    List<SObject> records = decision.getRecords();
    List<Database.SaveResult> saveResults = Database.update(records, false);
    for (Integer i = 0; i < saveResults.size(); i++) {
      if (saveResults[i].isSuccess()) {
        result.updatedRecordIds.add(saveResults[i].getId());
      } else {
        for (Database.Error error : saveResults[i].getErrors()) {
          result.errors.add(
            records[i].getSObjectType().getDescribe().getName() +
              ': ' +
              error.getMessage()
          );
        }
      }
    }
  }

  /**
   * Resolves the handler by class name (Type.forName) and invokes it.
   * Resolution and handler failures are reported on the Result; extraction
   * updates from the same run are not rolled back.
   */
  private static void invokeMismatchHandler(
    String handlerName,
    ComplianceReport report,
    Result result
  ) {
    Type handlerType = Type.forName(handlerName);
    if (handlerType == null) {
      result.errors.add(
        'Mismatch handler class "' + handlerName + '" was not found.'
      );
      return;
    }
    Object instance;
    try {
      instance = handlerType.newInstance();
    } catch (Exception e) {
      result.errors.add(
        'Mismatch handler "' +
          handlerName +
          '" could not be instantiated: ' +
          e.getMessage()
      );
      return;
    }
    if (!(instance instanceof IComplianceMismatchHandler)) {
      result.errors.add(
        'Mismatch handler "' +
          handlerName +
          '" does not implement IComplianceMismatchHandler.'
      );
      return;
    }
    try {
      ((IComplianceMismatchHandler) instance).handle(report);
    } catch (Exception e) {
      result.errors.add(
        'Mismatch handler "' + handlerName + '" failed: ' + e.getMessage()
      );
    }
  }

  private static String normalizeMode(String mode) {
    String trimmed = mode == null ? '' : mode.trim();
    if (
      trimmed.equalsIgnoreCase(MODE_EXTRACTION) ||
      trimmed.equalsIgnoreCase('Data Extraction')
    ) {
      return MODE_EXTRACTION;
    }
    if (
      trimmed.equalsIgnoreCase(MODE_COMPLIANCE) ||
      trimmed.equalsIgnoreCase('Compliance Check')
    ) {
      return MODE_COMPLIANCE;
    }
    return MODE_INVALID;
  }

  /**
   * Groups the rules into per-object anchor requests: the target fields to
   * query plus the optional Anchor_Filter__c narrowing which record
   * anchors. Rules arrive ordered by DeveloperName; the first non-blank
   * filter per object wins.
   */
  private static Map<String, DocumentContextResolver.AnchorRequest> anchorRequests(
    List<JSON_Field_Mapping__mdt> rules
  ) {
    Map<String, DocumentContextResolver.AnchorRequest> requests = new Map<String, DocumentContextResolver.AnchorRequest>();
    for (JSON_Field_Mapping__mdt rule : rules) {
      DocumentContextResolver.AnchorRequest request = requests.get(
        rule.Target_Object__c
      );
      if (request == null) {
        request = new DocumentContextResolver.AnchorRequest();
        requests.put(rule.Target_Object__c, request);
      }
      request.fields.add(rule.Target_Field__c);
      if (
        String.isBlank(request.filter) &&
        String.isNotBlank(rule.Anchor_Filter__c)
      ) {
        request.filter = rule.Anchor_Filter__c;
      }
    }
    return requests;
  }
}
