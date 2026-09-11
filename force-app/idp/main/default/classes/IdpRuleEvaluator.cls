/**
 * Evaluates one rule against one record: read the JSON (confidence
 * envelopes included), parse through the rule's value type, apply the
 * gates (Required, Minimum Confidence, Minimum Grade), then either stage
 * a write (Extraction / Preview) or compare both sides through the type
 * (Compliance). Every outcome that is not a clean write or a clean match
 * becomes a Finding with full context.
 *
 * @group IDP Engine
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpRuleEvaluator {
  /** Which row of a repeating section a finding belongs to; null for
   *  fixed sections. */
  public class RowInfo {
    /** Section the row belongs to. */
    public String sectionName;
    /** 0-based row position within the section. */
    public Integer index;
    /** Row match key, as rendered from the section's template. */
    public String key;

    /**
     * Places a finding on one row of a repeating section.
     *
     * @param sectionName Section the row belongs to.
     * @param index 0-based row position.
     * @param key Row match key.
     */
    public RowInfo(String sectionName, Integer index, String key) {
      this.sectionName = sectionName;
      this.index = index;
      this.key = key;
    }
  }

  /**
   * Evaluates one rule against one record.
   *
   * Reads the JSON, parses through the rule's value type and applies the
   * Required, Minimum Confidence and Minimum Grade gates, then stages a
   * write, hands the field to custom Apex, or compares both sides. Every
   * outcome that is neither a clean write nor a clean match becomes a
   * Finding carrying full context.
   *
   * @param rule Rule being evaluated.
   * @param effectiveMode Mode this rule runs under, after any override.
   * @param previewing True when no DML may happen.
   * @param scope JSON root for fixed sections, the row for repeating ones.
   * @param record Target record, mutated in memory before it is staged.
   * @param objectName API name of the target object.
   * @param row Row the rule belongs to; null for fixed sections.
   * @param result Document result collecting findings and planned changes.
   * @param executor Executor the write is staged through.
   */
  public static void apply(
    IdpConfigLoader.RuleConfig rule,
    String effectiveMode,
    Boolean previewing,
    Object scope,
    SObject record,
    String objectName,
    RowInfo row,
    IdpResult.Result result,
    IdpDmlExecutor executor
  ) {
    Schema.DescribeFieldResult describe = IdpSchemaCache.fieldDescribe(
      objectName,
      rule.targetField
    );
    if (describe == null) {
      contextualize(
        result.add(
          IdpResult.CODE_UNKNOWN_FIELD,
          IdpResult.SEV_ERROR,
          'Unknown field ' + objectName + '.' + rule.targetField + '.'
        ),
        rule,
        objectName,
        record,
        row
      );
      return;
    }

    // Preview never runs custom Apex (it may have side effects), and must
    // say so — otherwise a user approves a change set that is not what
    // will actually happen.
    if (effectiveMode == IdpMappingEngine.MODE_CUSTOM && previewing) {
      IdpResult.Finding skipped = result.add(
        IdpResult.CODE_HANDLER_SKIPPED,
        IdpResult.SEV_INFO,
        'Rule ' +
          rule.label +
          ' hands its field to custom Apex, which does not run in Preview; ' +
          'the planned changes do not include whatever it would write.'
      );
      contextualize(skipped, rule, objectName, record, row);
      return;
    }

    IdpJsonReader.ValueAt read = IdpJsonReader.readWithConfidence(
      scope,
      rule.jsonPath
    );
    // ENG-9: a weighted field that resolved with a confidence contributes
    // to the document score whatever the gates decide below — the envelope
    // measures the extraction, not the parse.
    if (read.value != null) {
      result.addConfidenceSample(rule.confidenceWeight, read.confidence);
    }
    if (read.value == null) {
      if (rule.required) {
        contextualize(
          result.add(
            IdpResult.CODE_REQUIRED_MISSING,
            IdpResult.SEV_ERROR,
            'The document has no value at required path "' +
              rule.jsonPath +
              '".'
          ),
          rule,
          objectName,
          record,
          row
        );
      }
      return; // path absent — nothing to map or check
    }
    if (
      rule.minConfidence != null &&
      read.confidence != null &&
      read.confidence < rule.minConfidence
    ) {
      IdpResult.Finding low = result.add(
        IdpResult.CODE_LOW_CONFIDENCE,
        IdpResult.SEV_WARNING,
        'Confidence ' +
          read.confidence +
          ' is below the rule\'s minimum ' +
          rule.minConfidence +
          '; the value was not used.'
      );
      low.confidence = read.confidence;
      low.rawValue = String.valueOf(read.value);
      contextualize(low, rule, objectName, record, row);
      return;
    }

    // The overwrite policy is decided before parsing: a value that will
    // not be written must not be able to fail the run.
    Object stored = currentValue(record, describe.getName());
    if (
      effectiveMode != IdpMappingEngine.MODE_COMPLIANCE &&
      rule.overwritePolicy == 'Only if blank' &&
      stored != null &&
      String.valueOf(stored) != ''
    ) {
      return;
    }

    // Resolve the value type: the rule's explicit one, or a strict
    // auto-type from the field describe.
    IValueType type = rule.type;
    IdpValueTypes.Config typeConfig = rule.typeConfig;
    if (type == null) {
      typeConfig = IdpTypeRegistry.autoConfig(describe);
      type = IdpTypeRegistry.builtIn(typeConfig.kind);
    }

    IdpValueTypes.ParseResult parsed = type.parse(read.value, typeConfig);
    if (parsed.grade == IdpResult.Grade.FAILED) {
      IdpResult.Finding failure = result.add(
        IdpResult.CODE_PARSE_FAILED,
        IdpResult.SEV_ERROR,
        parsed.note
      );
      failure.rawValue = String.valueOf(read.value);
      failure.grade = IdpResult.label(parsed.grade);
      contextualize(failure, rule, objectName, record, row);
      return;
    }
    if (parsed.grade == IdpResult.Grade.AMBIGUOUS) {
      IdpResult.Finding ambiguity = result.add(
        IdpResult.CODE_PARSE_AMBIGUOUS,
        IdpResult.SEV_WARNING,
        parsed.note
      );
      ambiguity.rawValue = String.valueOf(read.value);
      ambiguity.grade = IdpResult.label(parsed.grade);
      contextualize(ambiguity, rule, objectName, record, row);
      return; // never guess
    }
    if (IdpResult.rank(parsed.grade) > IdpResult.rank(rule.minGrade)) {
      IdpResult.Finding gated = result.add(
        IdpResult.CODE_BELOW_MIN_GRADE,
        IdpResult.SEV_WARNING,
        'The value parsed as ' +
          IdpResult.label(parsed.grade) +
          ' but the rule requires ' +
          IdpResult.label(rule.minGrade) +
          (String.isBlank(parsed.note) ? '.' : ': ' + parsed.note)
      );
      gated.rawValue = String.valueOf(read.value);
      gated.grade = IdpResult.label(parsed.grade);
      contextualize(gated, rule, objectName, record, row);
      return;
    }

    // A money amount only means something in its currency. In a
    // multi-currency org, a document denominated differently from the
    // record must never write (or "confirm") an amount — 100 EUR is not
    // 100 ZAR however equal the numbers are.
    if (
      parsed.currencyCode != null &&
      describe.getType() == Schema.DisplayType.CURRENCY
    ) {
      Object recordCurrency = currentValue(record, 'CurrencyIsoCode');
      if (
        recordCurrency != null &&
        String.valueOf(recordCurrency) != parsed.currencyCode
      ) {
        IdpResult.Finding clash = result.add(
          IdpResult.CODE_CURRENCY_MISMATCH,
          IdpResult.SEV_ERROR,
          'The document amount is in ' +
            parsed.currencyCode +
            ' but the record is denominated in ' +
            String.valueOf(recordCurrency) +
            '; the value was not used.'
        );
        clash.rawValue = String.valueOf(read.value);
        clash.extractedValue = parsed.currencyCode;
        clash.storedValue = String.valueOf(recordCurrency);
        contextualize(clash, rule, objectName, record, row);
        return;
      }
    }

    if (effectiveMode == IdpMappingEngine.MODE_COMPLIANCE) {
      compare(
        rule,
        type,
        typeConfig,
        parsed,
        read,
        record,
        objectName,
        row,
        result
      );
      return;
    }

    if (effectiveMode == IdpMappingEngine.MODE_CUSTOM) {
      runFieldHandler(
        rule,
        parsed,
        read,
        record,
        objectName,
        row,
        result,
        executor
      );
      return;
    }

    // Extraction (or Preview): coerce and stage.
    Object coerced;
    try {
      coerced = IdpValueTypes.coerceForField(
        describe,
        parsed.value,
        type,
        typeConfig
      );
    } catch (IdpValueTypes.TypeException e) {
      IdpResult.Finding failure = result.add(
        IdpResult.CODE_PARSE_FAILED,
        IdpResult.SEV_ERROR,
        e.getMessage()
      );
      failure.rawValue = String.valueOf(read.value);
      contextualize(failure, rule, objectName, record, row);
      return;
    }
    if (
      !validatePicklist(
        describe,
        coerced,
        rule,
        objectName,
        record,
        row,
        result
      )
    ) {
      return;
    }

    IdpResult.PlannedChange change = new IdpResult.PlannedChange();
    change.objectName = objectName;
    change.recordId = record.Id;
    change.fieldName = describe.getName();
    change.oldValue = stored == null ? null : String.valueOf(stored);
    change.newValue = String.valueOf(coerced);
    change.grade = IdpResult.label(parsed.grade);
    change.isNew = record.Id == null;
    if (row != null) {
      change.sectionName = row.sectionName;
      change.rowIndex = row.index;
    }
    result.plannedChanges.add(change);

    if (record.Id == null) {
      // A record the run is creating (ENG-2/ENG-3): the value rides along
      // on the staged insert, so there is nothing to stage separately.
      record.put(describe.getName(), coerced);
    } else {
      executor.stage(
        result,
        record.getSObjectType(),
        record.Id,
        describe.getName(),
        coerced,
        row != null
      );
    }
    if (!previewing) {
      result.fieldsApplied++;
    }
  }

  /**
   * Hands a parsed field to the rule's IIdpFieldHandler (ENG-1).
   *
   * The handler mutates the record in memory; every field it changed is
   * staged through the executor afterwards, so the run's single
   * FLS-stripped update still holds. On a record the run is creating, the
   * mutations ride along on the insert and no diff is needed. A thrown
   * exception becomes a HANDLER_FAILED finding.
   *
   * @param rule Rule naming the handler class.
   * @param parsed Parse outcome handed to the handler.
   * @param read Raw value and confidence read from the document.
   * @param record Target record the handler may mutate.
   * @param objectName API name of the target object.
   * @param row Row the rule belongs to; null for fixed sections.
   * @param result Document result collecting findings.
   * @param executor Executor the diffed writes are staged through.
   */
  private static void runFieldHandler(
    IdpConfigLoader.RuleConfig rule,
    IdpValueTypes.ParseResult parsed,
    IdpJsonReader.ValueAt read,
    SObject record,
    String objectName,
    RowInfo row,
    IdpResult.Result result,
    IdpDmlExecutor executor
  ) {
    IdpFieldContext context = new IdpFieldContext();
    context.jsonPath = rule.jsonPath;
    context.targetObject = objectName;
    context.targetField = rule.targetField;
    context.rawValue = read.value;
    context.parsedValue = parsed.value;
    context.grade = IdpResult.label(parsed.grade);
    context.confidence = read.confidence;
    context.record = record;
    if (row != null) {
      context.sectionName = row.sectionName;
      context.rowIndex = row.index;
      context.rowKey = row.key;
    }

    Map<String, Object> before = record.Id == null
      ? null
      : new Map<String, Object>(record.getPopulatedFieldsAsMap());
    try {
      rule.fieldHandler.handle(context);
    } catch (Exception e) {
      IdpResult.Finding failure = result.add(
        IdpResult.CODE_HANDLER_FAILED,
        IdpResult.SEV_ERROR,
        'Rule ' + rule.label + ': the field handler failed — ' + e.getMessage()
      );
      failure.rawValue = String.valueOf(read.value);
      contextualize(failure, rule, objectName, record, row);
      return;
    }
    if (before == null) {
      return; // new record — mutations are already on the staged insert
    }
    Map<String, Object> after = record.getPopulatedFieldsAsMap();
    for (String fieldName : after.keySet()) {
      Object value = after.get(fieldName);
      if (fieldName == 'Id' || value instanceof SObject) {
        continue; // identity and parent relationships are not writes
      }
      Boolean changed =
        !before.containsKey(fieldName) || before.get(fieldName) != value;
      if (changed) {
        executor.stage(
          result,
          record.getSObjectType(),
          record.Id,
          fieldName,
          value,
          row != null
        );
        result.fieldsApplied++;
      }
    }
  }

  /**
   * Weighs a document value against the value the record already holds.
   *
   * Both sides go through the type's canonical form and the verdict is
   * three-state. A blank stored field cannot confirm the document, so it
   * counts as a mismatch.
   *
   * @param rule Rule being compared.
   * @param type Value type resolving both sides.
   * @param typeConfig Configuration driving the comparison.
   * @param parsed Parse outcome for the document value.
   * @param read Raw value and confidence read from the document.
   * @param record Record holding the stored value.
   * @param objectName API name of the target object.
   * @param row Row the rule belongs to; null for fixed sections.
   * @param result Document result collecting findings.
   */
  private static void compare(
    IdpConfigLoader.RuleConfig rule,
    IValueType type,
    IdpValueTypes.Config typeConfig,
    IdpValueTypes.ParseResult parsed,
    IdpJsonReader.ValueAt read,
    SObject record,
    String objectName,
    RowInfo row,
    IdpResult.Result result
  ) {
    result.fieldsCompared++;
    Object stored = currentValue(record, rule.targetField);
    IdpResult.CompareOutcome outcome = type.compare(
      parsed.value,
      stored,
      typeConfig
    );
    if (outcome == IdpResult.CompareOutcome.MATCH) {
      return;
    }
    IdpResult.Finding finding = result.add(
      outcome == IdpResult.CompareOutcome.NEAR
        ? IdpResult.CODE_VALUE_NEAR
        : IdpResult.CODE_VALUE_MISMATCH,
      IdpResult.SEV_WARNING,
      (outcome == IdpResult.CompareOutcome.NEAR
          ? 'Near match on '
          : 'Mismatch on ') +
        objectName +
        '.' +
        rule.targetField +
        ': the document says "' +
        String.valueOf(read.value) +
        '", the record holds "' +
        (stored == null ? '' : String.valueOf(stored)) +
        '".'
    );
    finding.rawValue = String.valueOf(read.value);
    finding.extractedValue = type.render(parsed.value, typeConfig);
    finding.storedValue = stored == null ? null : String.valueOf(stored);
    finding.grade = IdpResult.label(parsed.grade);
    finding.compareOutcome = outcome == IdpResult.CompareOutcome.NEAR
      ? 'Near'
      : 'Mismatch';
    finding.confidence = read.confidence;
    contextualize(finding, rule, objectName, record, row);
  }

  /**
   * Keeps a value out of a restricted picklist unless it is an active entry.
   *
   * @param describe Describe of the target field.
   * @param coerced Value about to be written.
   * @param rule Rule supplying the value.
   * @param objectName API name of the target object.
   * @param record Target record, for finding context.
   * @param row Row the rule belongs to; null for fixed sections.
   * @param result Document result collecting findings.
   * @return True when the write may proceed.
   */
  private static Boolean validatePicklist(
    Schema.DescribeFieldResult describe,
    Object coerced,
    IdpConfigLoader.RuleConfig rule,
    String objectName,
    SObject record,
    RowInfo row,
    IdpResult.Result result
  ) {
    if (
      describe.getType() != Schema.DisplayType.PICKLIST &&
      describe.getType() != Schema.DisplayType.MULTIPICKLIST
    ) {
      return true;
    }
    if (!describe.isRestrictedPicklist() || coerced == null) {
      return true;
    }
    String candidate = String.valueOf(coerced);
    for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
      if (entry.isActive() && entry.getValue() == candidate) {
        return true;
      }
    }
    contextualize(
      result.add(
        IdpResult.CODE_PICKLIST_INVALID,
        IdpResult.SEV_ERROR,
        '"' +
          candidate +
          '" is not an active value of picklist ' +
          describe.getName() +
          '.'
      ),
      rule,
      objectName,
      record,
      row
    );
    return false;
  }

  /**
   * Attaches the rule, record and row a finding arose from.
   *
   * @param finding Finding to enrich.
   * @param rule Rule being evaluated.
   * @param objectName API name of the target object.
   * @param record Target record; may be null.
   * @param row Row the rule belongs to; null for fixed sections.
   */
  private static void contextualize(
    IdpResult.Finding finding,
    IdpConfigLoader.RuleConfig rule,
    String objectName,
    SObject record,
    RowInfo row
  ) {
    finding.objectName = objectName;
    finding.recordId = record == null ? null : record.Id;
    finding.fieldName = rule.targetField;
    finding.jsonPath = rule.jsonPath;
    if (row != null) {
      finding.sectionName = row.sectionName;
      finding.rowIndex = row.index;
      finding.rowKey = row.key;
    }
  }

  /**
   * Reads a field that may not have been queried.
   *
   * @param record Record to read from.
   * @param fieldName API name of the field.
   * @return Stored value, or null when the field is unavailable.
   */
  private static Object currentValue(SObject record, String fieldName) {
    try {
      return record.get(fieldName);
    } catch (Exception e) {
      return null; // not queried (e.g. FLS) — treat as blank
    }
  }
}
