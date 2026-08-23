/**
 * Evaluates one rule against one record: read the JSON (confidence
 * envelopes included), parse through the rule's value type, apply the
 * gates (Required, Minimum Confidence, Minimum Grade), then either stage
 * a write (Extraction / Preview) or compare both sides through the type
 * (Compliance). Every outcome that is not a clean write or a clean match
 * becomes a Finding with full context.
 */
public inherited sharing class IdpRuleEvaluator {
  /** Which row of a repeating section a finding belongs to; null for
   *  fixed sections. */
  public class RowInfo {
    public String sectionName;
    public Integer index;
    public String key;

    public RowInfo(String sectionName, Integer index, String key) {
      this.sectionName = sectionName;
      this.index = index;
      this.key = key;
    }
  }

  public static void apply(
    IdpConfigLoader.RuleConfig rule,
    String effectiveMode,
    Boolean previewing,
    Object scope, // the JSON root for fixed sections, the row for repeating
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

    IdpJsonReader.ValueAt read = IdpJsonReader.readWithConfidence(
      scope,
      rule.jsonPath
    );
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
    if (row != null) {
      change.sectionName = row.sectionName;
      change.rowIndex = row.index;
    }
    result.plannedChanges.add(change);

    executor.stage(
      result,
      record.getSObjectType(),
      record.Id,
      describe.getName(),
      coerced,
      row != null
    );
    if (!previewing) {
      result.fieldsApplied++;
    }
  }

  /** Compliance: both sides go through the type's canonical form; the
   *  verdict is three-state. A blank stored field cannot confirm the
   *  document, so it is a mismatch. */
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

  private static Object currentValue(SObject record, String fieldName) {
    try {
      return record.get(fieldName);
    } catch (Exception e) {
      return null; // not queried (e.g. FLS) — treat as blank
    }
  }
}
