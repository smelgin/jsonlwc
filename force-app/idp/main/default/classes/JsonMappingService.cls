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
  private static final String SECTION_REPEATING = 'Repeating';

  /**
   * A rule together with the object and filter it actually writes to. Those
   * come from the rule itself when it is standalone (the original shape,
   * still fully supported) and from its section otherwise.
   */
  private class ResolvedRule {
    public JSON_Field_Mapping__mdt rule;
    public String objectName;
    public String filter;

    public ResolvedRule(JSON_Field_Mapping__mdt rule) {
      this.rule = rule;
      this.objectName = rule.Target_Object__c;
      this.filter = rule.Anchor_Filter__c;
    }

    public ResolvedRule(
      JSON_Field_Mapping__mdt rule,
      JSON_Mapping_Section__mdt section
    ) {
      this.rule = rule;
      this.objectName = section.Target_Object__c;
      this.filter = String.isNotBlank(section.Record_Filter__c)
        ? section.Record_Filter__c
        : rule.Anchor_Filter__c;
    }
  }

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
    public Integer rowsMatched;

    @InvocableVariable
    @AuraEnabled
    public Integer rowsUpdated;

    @InvocableVariable
    @AuraEnabled
    public List<String> unmatchedRowKeys;

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

    /** Repeating sections only: which row of the document differed. */
    @InvocableVariable
    @AuraEnabled
    public String sectionName;

    @InvocableVariable
    @AuraEnabled
    public Integer rowIndex;

    @InvocableVariable
    @AuraEnabled
    public String rowKey;
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
    result.rowsMatched = 0;
    result.rowsUpdated = 0;
    result.unmatchedRowKeys = new List<String>();
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

    Map<String, JSON_Mapping_Section__mdt> sections = sectionsByName(
      mappingSetName
    );

    // Standalone rules and rules on a Fixed section both write to a single
    // record per object; rules on a Repeating section iterate its rows.
    List<ResolvedRule> singleRules = new List<ResolvedRule>();
    Map<String, List<JSON_Field_Mapping__mdt>> rulesBySection = new Map<String, List<JSON_Field_Mapping__mdt>>();
    for (JSON_Field_Mapping__mdt rule : rules) {
      if (String.isBlank(rule.Section__c)) {
        singleRules.add(new ResolvedRule(rule));
        continue;
      }
      JSON_Mapping_Section__mdt section = sections.get(rule.Section__c);
      if (section == null) {
        result.errors.add(
          'Rule ' +
            rule.JSON_Path__c +
            ' points at unknown or inactive section "' +
            rule.Section__c +
            '".'
        );
        continue;
      }
      if (section.Section_Type__c == SECTION_REPEATING) {
        if (!rulesBySection.containsKey(section.Section_Name__c)) {
          rulesBySection.put(
            section.Section_Name__c,
            new List<JSON_Field_Mapping__mdt>()
          );
        }
        rulesBySection.get(section.Section_Name__c).add(rule);
      } else {
        singleRules.add(new ResolvedRule(rule, section));
      }
    }

    Map<String, SObject> anchors = DocumentContextResolver.resolve(
      contentDocumentId,
      anchorRequests(singleRules, sections, rulesBySection.keySet()),
      root
    );

    // One pending update per touched object, carrying only mapped fields
    // so unrelated queried values are never written back.
    Map<String, SObject> pending = new Map<String, SObject>();
    for (ResolvedRule resolved : singleRules) {
      String ruleMode = effectiveMode(resolved.rule, runMode, result);
      if (ruleMode != MODE_INVALID) {
        applyRule(resolved, ruleMode, root, anchors, pending, result);
      }
    }

    List<SObject> rowUpdates = new List<SObject>();
    for (String sectionName : rulesBySection.keySet()) {
      processRepeatingSection(
        sections.get(sectionName),
        rulesBySection.get(sectionName),
        sections,
        runMode,
        root,
        anchors,
        rowUpdates,
        result
      );
    }

    if (!pending.isEmpty()) {
      saveUpdates(pending.values(), false, result);
    }
    if (!rowUpdates.isEmpty()) {
      saveUpdates(rowUpdates, true, result);
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
    ResolvedRule resolved,
    String ruleMode,
    Object root,
    Map<String, SObject> anchors,
    Map<String, SObject> pending,
    Result result
  ) {
    JSON_Field_Mapping__mdt rule = resolved.rule;
    String objectName = resolved.objectName;
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
      checkCompliance(rule, objectName, anchor, field, value, null, result);
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
    String objectName,
    SObject record,
    Schema.SObjectField field,
    Object extracted,
    RowContext row,
    Result result
  ) {
    result.fieldsCompared++;
    Object actual = currentValue(record, field.getDescribe().getName());
    if (valuesMatch(extracted, actual)) {
      return;
    }
    Mismatch mismatch = new Mismatch();
    mismatch.objectName = objectName;
    mismatch.recordId = record.Id;
    mismatch.fieldName = rule.Target_Field__c;
    mismatch.jsonPath = rule.JSON_Path__c;
    mismatch.extractedValue = String.valueOf(extracted);
    mismatch.actualValue = actual == null ? null : String.valueOf(actual);
    if (row != null) {
      mismatch.sectionName = row.sectionName;
      mismatch.rowIndex = row.index;
      mismatch.rowKey = row.key;
    }
    result.mismatches.add(mismatch);
  }

  /**
   * Repeating section: reads the array at Row_Path__c, builds each row's key
   * from Match_Value__c, then matches those keys against existing records in
   * ONE query — so a 200-line document costs the same as a 2-line one. Rows
   * with no matching record are reported in unmatchedRowKeys; this version
   * updates existing records only and never creates them.
   */
  private static void processRepeatingSection(
    JSON_Mapping_Section__mdt section,
    List<JSON_Field_Mapping__mdt> sectionRules,
    Map<String, JSON_Mapping_Section__mdt> sections,
    String runMode,
    Object root,
    Map<String, SObject> anchors,
    List<SObject> rowUpdates,
    Result result
  ) {
    String label = 'Section "' + section.Section_Name__c + '"';
    if (
      String.isBlank(section.Row_Path__c) ||
      String.isBlank(section.Match_Field__c) ||
      String.isBlank(section.Match_Value__c)
    ) {
      result.errors.add(
        label + ' needs Row Path, Match Field and Match Value to map rows.'
      );
      return;
    }

    Object rowsRaw = JsonPathReader.read(root, section.Row_Path__c);
    if (rowsRaw == null) {
      return; // the document has no such region — not an error
    }
    if (!(rowsRaw instanceof List<Object>)) {
      result.errors.add(
        label + ': Row Path "' + section.Row_Path__c + '" is not a list.'
      );
      return;
    }
    List<Object> rows = (List<Object>) rowsRaw;
    if (rows.isEmpty()) {
      return;
    }

    // Keys in document order; a duplicate key would collapse two rows onto
    // one record, so it is reported rather than silently applied twice.
    List<String> keys = new List<String>();
    Map<String, Integer> rowIndexByKey = new Map<String, Integer>();
    for (Integer i = 0; i < rows.size(); i++) {
      String key = JsonFilterBinder.renderTemplate(
        section.Match_Value__c,
        root,
        rows[i],
        i
      );
      if (String.isBlank(key)) {
        result.errors.add(
          label + ': row ' + i + ' has no Match Value, so it was skipped.'
        );
      } else if (rowIndexByKey.containsKey(key)) {
        result.errors.add(
          label +
            ': rows ' +
            rowIndexByKey.get(key) +
            ' and ' +
            i +
            ' produce the same Match Value "' +
            key +
            '"; row ' +
            i +
            ' was skipped.'
        );
      } else {
        keys.add(key);
        rowIndexByKey.put(key, i);
      }
    }
    if (keys.isEmpty()) {
      return;
    }

    Map<String, SObject> recordsByKey = queryRows(
      section,
      sections,
      sectionRules,
      keys,
      anchors,
      root,
      result
    );
    if (recordsByKey == null) {
      return; // configuration problem already reported
    }

    for (String key : keys) {
      Integer index = rowIndexByKey.get(key);
      SObject record = recordsByKey.get(key);
      if (record == null) {
        result.unmatchedRowKeys.add(key);
        continue;
      }
      result.rowsMatched++;
      applyRowRules(
        section,
        sectionRules,
        rows[index],
        record,
        new RowContext(section.Section_Name__c, index, key),
        runMode,
        rowUpdates,
        result
      );
    }
  }

  /** Applies one row's rules to its matched record. Rule JSON paths are
   *  relative to the row element, so the same rules serve every row. */
  private static void applyRowRules(
    JSON_Mapping_Section__mdt section,
    List<JSON_Field_Mapping__mdt> sectionRules,
    Object row,
    SObject record,
    RowContext context,
    String runMode,
    List<SObject> rowUpdates,
    Result result
  ) {
    String objectName = section.Target_Object__c;
    Map<String, Schema.SObjectField> fields = record.getSObjectType()
      .getDescribe()
      .fields.getMap();
    Map<String, Object> valuesToSet = new Map<String, Object>();

    for (JSON_Field_Mapping__mdt rule : sectionRules) {
      String ruleMode = effectiveMode(rule, runMode, result);
      if (ruleMode == MODE_INVALID) {
        continue;
      }
      Schema.SObjectField field = fields.get(rule.Target_Field__c);
      if (field == null) {
        result.errors.add(
          'Unknown field ' + objectName + '.' + rule.Target_Field__c + '.'
        );
        continue;
      }
      Object raw = JsonPathReader.read(row, rule.JSON_Path__c);
      if (raw == null) {
        continue; // this row does not carry that value
      }
      Object value;
      try {
        value = FieldValueCoercer.coerce(
          field.getDescribe(),
          raw,
          rule.Transform__c
        );
      } catch (FieldValueCoercer.CoercionException e) {
        result.errors.add(
          objectName +
            '.' +
            rule.Target_Field__c +
            ' (row ' +
            context.index +
            '): ' +
            e.getMessage()
        );
        continue;
      }

      if (ruleMode == MODE_COMPLIANCE) {
        checkCompliance(
          rule,
          objectName,
          record,
          field,
          value,
          context,
          result
        );
        continue;
      }
      if (rule.Overwrite_Policy__c == POLICY_ONLY_IF_BLANK) {
        Object current = currentValue(record, rule.Target_Field__c);
        if (current != null && String.valueOf(current) != '') {
          continue;
        }
      }
      valuesToSet.put(rule.Target_Field__c, value);
    }

    if (valuesToSet.isEmpty()) {
      return;
    }
    SObject rowUpdate = record.getSObjectType().newSObject(record.Id);
    for (String fieldName : valuesToSet.keySet()) {
      rowUpdate.put(fieldName, valuesToSet.get(fieldName));
    }
    rowUpdates.add(rowUpdate);
    result.fieldsApplied += valuesToSet.size();
  }

  /**
   * Matches row keys to existing records in a single query, constrained to
   * the parent record resolved from the file so a key that is only unique
   * within one account cannot reach another account's rows.
   * Returns null when the section is misconfigured.
   */
  private static Map<String, SObject> queryRows(
    JSON_Mapping_Section__mdt section,
    Map<String, JSON_Mapping_Section__mdt> sections,
    List<JSON_Field_Mapping__mdt> sectionRules,
    List<String> keys,
    Map<String, SObject> anchors,
    Object root,
    Result result
  ) {
    String objectName = section.Target_Object__c;
    String label = 'Section "' + section.Section_Name__c + '"';
    Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectName);
    if (objectType == null) {
      result.errors.add(label + ': unknown object ' + objectName + '.');
      return null;
    }
    Map<String, Schema.SObjectField> described = objectType.getDescribe()
      .fields.getMap();
    Schema.SObjectField matchField = described.get(section.Match_Field__c);
    if (matchField == null || !matchField.getDescribe().isAccessible()) {
      result.errors.add(
        label +
          ': Match Field ' +
          objectName +
          '.' +
          section.Match_Field__c +
          ' does not exist or is not readable.'
      );
      return null;
    }
    String matchFieldName = matchField.getDescribe().getName();

    Set<String> selected = new Set<String>{ 'Id', matchFieldName };
    for (JSON_Field_Mapping__mdt rule : sectionRules) {
      Schema.SObjectField field = described.get(rule.Target_Field__c);
      if (field != null && field.getDescribe().isAccessible()) {
        selected.add(field.getDescribe().getName());
      }
    }

    Map<String, Object> binds = new Map<String, Object>{ 'keys' => keys };
    String whereClause = matchFieldName + ' IN :keys';

    String parentObject = parentObjectFor(section, sections, anchors);
    if (parentObject != null) {
      String lookup = DocumentContextResolver.findLookupTo(
        objectName,
        parentObject
      );
      if (lookup != null) {
        binds.put('parentId', anchors.get(parentObject).Id);
        whereClause += ' AND ' + lookup + ' = :parentId';
      }
    }
    if (String.isNotBlank(section.Record_Filter__c)) {
      whereClause +=
        ' AND (' +
        JsonFilterBinder.bindFilter(
          section.Record_Filter__c,
          root,
          null,
          null,
          binds
        ) +
        ')';
    }

    String soql =
      'SELECT ' +
      String.join(new List<String>(selected), ', ') +
      ' FROM ' +
      objectName +
      ' WHERE ' +
      whereClause;
    Map<String, SObject> byKey = new Map<String, SObject>();
    try {
      for (
        SObject record : Database.queryWithBinds(
          soql,
          binds,
          AccessLevel.USER_MODE
        )
      ) {
        Object keyValue = record.get(matchFieldName);
        if (keyValue != null) {
          byKey.put(String.valueOf(keyValue), record);
        }
      }
    } catch (Exception e) {
      result.errors.add(label + ': row lookup failed — ' + e.getMessage());
      return null;
    }
    return byKey;
  }

  /**
   * Object whose resolved record constrains a section's rows: the declared
   * Parent Section when given, otherwise the resolved record this object has
   * a lookup to. Anchor names are sorted so the choice is deterministic.
   */
  private static String parentObjectFor(
    JSON_Mapping_Section__mdt section,
    Map<String, JSON_Mapping_Section__mdt> sections,
    Map<String, SObject> anchors
  ) {
    if (String.isNotBlank(section.Parent_Section__c)) {
      JSON_Mapping_Section__mdt parent = sections.get(
        section.Parent_Section__c
      );
      if (parent != null && anchors.containsKey(parent.Target_Object__c)) {
        return parent.Target_Object__c;
      }
      return null;
    }
    List<String> anchored = new List<String>(anchors.keySet());
    anchored.sort();
    for (String candidate : anchored) {
      if (
        DocumentContextResolver.findLookupTo(
          section.Target_Object__c,
          candidate
        ) != null
      ) {
        return candidate;
      }
    }
    return null;
  }

  private static Map<String, JSON_Mapping_Section__mdt> sectionsByName(
    String mappingSetName
  ) {
    Map<String, JSON_Mapping_Section__mdt> byName = new Map<String, JSON_Mapping_Section__mdt>();
    for (
      JSON_Mapping_Section__mdt section : JsonMappingSelector.selectSections(
        mappingSetName
      )
    ) {
      byName.put(section.Section_Name__c, section);
    }
    return byName;
  }

  private static String effectiveMode(
    JSON_Field_Mapping__mdt rule,
    String runMode,
    Result result
  ) {
    if (String.isBlank(rule.Mode__c)) {
      return runMode;
    }
    String ruleMode = normalizeMode(rule.Mode__c);
    if (ruleMode == MODE_INVALID) {
      result.errors.add(
        'Rule ' +
          rule.JSON_Path__c +
          ' has unknown Mode__c "' +
          rule.Mode__c +
          '".'
      );
    }
    return ruleMode;
  }

  /** Identifies which row of a repeating section a finding belongs to. */
  private class RowContext {
    public String sectionName;
    public Integer index;
    public String key;

    public RowContext(String sectionName, Integer index, String key) {
      this.sectionName = sectionName;
      this.index = index;
      this.key = key;
    }
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

  private static void saveUpdates(
    List<SObject> pending,
    Boolean areRows,
    Result result
  ) {
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
        if (areRows) {
          result.rowsUpdated++;
        }
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
   * Builds the per-object anchor requests the resolver needs: the fields
   * single-record rules read or write, plus the parent objects repeating
   * sections constrain their rows by. Rules arrive ordered by DeveloperName,
   * so the first non-blank filter per object wins.
   */
  private static Map<String, DocumentContextResolver.AnchorRequest> anchorRequests(
    List<ResolvedRule> singleRules,
    Map<String, JSON_Mapping_Section__mdt> sections,
    Set<String> repeatingSectionNames
  ) {
    Map<String, DocumentContextResolver.AnchorRequest> requests = new Map<String, DocumentContextResolver.AnchorRequest>();
    for (ResolvedRule resolved : singleRules) {
      DocumentContextResolver.AnchorRequest request = requests.get(
        resolved.objectName
      );
      if (request == null) {
        request = new DocumentContextResolver.AnchorRequest();
        requests.put(resolved.objectName, request);
      }
      request.fields.add(resolved.rule.Target_Field__c);
      if (
        String.isBlank(request.filter) && String.isNotBlank(resolved.filter)
      ) {
        request.filter = resolved.filter;
      }
    }
    // A repeating section's rows hang off a parent record, so that parent
    // must be resolved even when no rule writes to it.
    for (String sectionName : repeatingSectionNames) {
      String parentName = sections.get(sectionName).Parent_Section__c;
      if (String.isBlank(parentName)) {
        continue;
      }
      JSON_Mapping_Section__mdt parent = sections.get(parentName);
      if (parent != null && !requests.containsKey(parent.Target_Object__c)) {
        DocumentContextResolver.AnchorRequest request = new DocumentContextResolver.AnchorRequest();
        request.filter = parent.Record_Filter__c;
        requests.put(parent.Target_Object__c, request);
      }
    }
    return requests;
  }
}
