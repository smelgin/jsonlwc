/**
 * Unit tests for config assembly and validation, at the Raw* DTO level —
 * custom metadata cannot be inserted in tests, and the query→raw mapping
 * is mechanical. What matters is that misconfiguration degrades to issues
 * while the rest of the set still runs.
 */
@IsTest
private class IdpConfigLoaderTest {
  private static IdpConfigLoader.RawSet rawSet() {
    IdpConfigLoader.RawSet raw = new IdpConfigLoader.RawSet();
    raw.name = 'Test_Set';
    raw.label = 'Test Set';
    raw.defaultMode = 'Extraction';
    return raw;
  }

  private static IdpConfigLoader.RawSection rawSection(
    String name,
    String sectionType,
    String targetObject
  ) {
    IdpConfigLoader.RawSection raw = new IdpConfigLoader.RawSection();
    raw.name = name;
    raw.label = name;
    raw.sectionType = sectionType;
    raw.targetObject = targetObject;
    return raw;
  }

  private static IdpConfigLoader.RawRule rawRule(
    String name,
    String sectionName,
    String jsonPath,
    String targetObject,
    String targetField
  ) {
    IdpConfigLoader.RawRule raw = new IdpConfigLoader.RawRule();
    raw.name = name;
    raw.label = name;
    raw.sectionName = sectionName;
    raw.jsonPath = jsonPath;
    raw.targetObject = targetObject;
    raw.targetField = targetField;
    return raw;
  }

  private static IdpConfigLoader.SetConfig assemble(
    IdpConfigLoader.RawSet mappingSet,
    List<IdpConfigLoader.RawSection> sections,
    List<IdpConfigLoader.RawRule> rules,
    Map<String, IdpValueTypes.Config> valueTypes
  ) {
    return IdpConfigLoader.assemble(mappingSet, sections, rules, valueTypes);
  }

  @IsTest
  static void missingSetIsAnError() {
    IdpConfigLoader.SetConfig config = assemble(
      null,
      new List<IdpConfigLoader.RawSection>(),
      new List<IdpConfigLoader.RawRule>(),
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.isFalse(config.found);
    Assert.areEqual(1, config.issues.size());
    Assert.areEqual(IdpResult.SEV_ERROR, config.issues[0].severity);
  }

  @IsTest
  static void assemblesValidConfig() {
    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{
        rawSection('Header', 'Fixed', 'Case')
      },
      new List<IdpConfigLoader.RawRule>{
        rawRule('Name_Rule', 'Header', 'applicant.name', 'Case', 'SuppliedName')
      },
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.isTrue(config.found);
    Assert.areEqual(0, config.issues.size(), 'issues: ' + config.issues);
    Assert.areEqual(1, config.sections.size());
    IdpConfigLoader.RuleConfig rule = config.sections[0].rules[0];
    Assert.areEqual('Case', rule.targetObject, 'inherited from the section');
    Assert.areEqual(
      IdpResult.Grade.INFERRED,
      rule.minGrade,
      'default gate allows Exact and Inferred'
    );
    Assert.isNull(rule.type, 'no explicit value type — auto at evaluation');
  }

  @IsTest
  static void objectMismatchSkipsTheRule() {
    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{
        rawSection('Header', 'Fixed', 'Case')
      },
      new List<IdpConfigLoader.RawRule>{
        rawRule('Bad_Rule', 'Header', 'x', 'Account', 'Phone'),
        rawRule('Good_Rule', 'Header', 'y', 'Case', 'Description')
      },
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(1, config.sections[0].rules.size(), 'one rule survives');
    Assert.areEqual('Good_Rule', config.sections[0].rules[0].name);
    Assert.areEqual(1, config.issues.size());
    Assert.isTrue(config.issues[0].message.contains('Bad_Rule'));
  }

  @IsTest
  static void incompleteRepeatingSectionIsSkippedWithItsRules() {
    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{
        rawSection('Lines', 'Repeating', 'Asset') // no row path/match config
      },
      new List<IdpConfigLoader.RawRule>{
        rawRule('Line_Rule', 'Lines', 'Quantity', 'Asset', 'Quantity')
      },
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(0, config.sections.size());
    Assert.areEqual(2, config.issues.size(), 'section skip + orphaned rule');
  }

  @IsTest
  static void unknownParentSectionIsDropped() {
    IdpConfigLoader.RawSection lines = rawSection(
      'Lines',
      'Repeating',
      'Asset'
    );
    lines.rowPath = 'Details';
    lines.matchField = 'SerialNumber';
    lines.matchValue = '{row:number}';
    lines.parentSection = 'Nowhere';
    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ lines },
      new List<IdpConfigLoader.RawRule>(),
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.isNull(config.sections[0].parentSectionName);
    Assert.areEqual(1, config.issues.size());
  }

  @IsTest
  static void unknownValueTypeSkipsTheRule() {
    IdpConfigLoader.RawRule rule = rawRule(
      'Typed_Rule',
      'Header',
      'x',
      'Case',
      'Description'
    );
    rule.valueTypeName = 'No_Such_Type';
    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{
        rawSection('Header', 'Fixed', 'Case')
      },
      new List<IdpConfigLoader.RawRule>{ rule },
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(0, config.sections[0].rules.size());
    Assert.isTrue(config.issues[0].message.contains('No_Such_Type'));
  }

  @IsTest
  static void unresolvableCustomHandlerSkipsTheRule() {
    IdpValueTypes.Config custom = new IdpValueTypes.Config();
    custom.name = 'Broken_Custom';
    custom.kind = IdpValueTypes.KIND_CUSTOM;
    custom.handlerClass = 'DoesNotExistAnywhere';
    IdpConfigLoader.RawRule rule = rawRule(
      'Custom_Rule',
      'Header',
      'x',
      'Case',
      'Description'
    );
    rule.valueTypeName = 'Broken_Custom';
    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{
        rawSection('Header', 'Fixed', 'Case')
      },
      new List<IdpConfigLoader.RawRule>{ rule },
      new Map<String, IdpValueTypes.Config>{ 'Broken_Custom' => custom }
    );
    Assert.areEqual(0, config.sections[0].rules.size());
    Assert.isTrue(config.issues[0].message.contains('DoesNotExistAnywhere'));
  }

  @IsTest
  static void validatesTypeConfigDetails() {
    IdpValueTypes.Config regex = new IdpValueTypes.Config();
    regex.name = 'Bad_Regex';
    regex.kind = IdpValueTypes.KIND_REGEX;
    regex.formatsRaw = '([unclosed';

    IdpValueTypes.Config phone = new IdpValueTypes.Config();
    phone.name = 'Bad_Region';
    phone.kind = IdpValueTypes.KIND_PHONE;
    phone.region = 'XX';

    IdpConfigLoader.RawRule regexRule = rawRule(
      'Regex_Rule',
      'Header',
      'a',
      'Case',
      'Subject'
    );
    regexRule.valueTypeName = 'Bad_Regex';
    IdpConfigLoader.RawRule phoneRule = rawRule(
      'Phone_Rule',
      'Header',
      'b',
      'Case',
      'SuppliedPhone'
    );
    phoneRule.valueTypeName = 'Bad_Region';

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{
        rawSection('Header', 'Fixed', 'Case')
      },
      new List<IdpConfigLoader.RawRule>{ regexRule, phoneRule },
      new Map<String, IdpValueTypes.Config>{
        'Bad_Regex' => regex,
        'Bad_Region' => phone
      }
    );
    Assert.areEqual(
      2,
      config.sections[0].rules.size(),
      'these are warnings, not rule-stoppers'
    );
    Assert.areEqual(2, config.issues.size());
  }

  @IsTest
  static void reportsLocalesTheOrgHasNotSeeded() {
    IdpValueTypes.Config unseeded = new IdpValueTypes.Config();
    unseeded.name = 'Bad_Locale';
    unseeded.kind = IdpValueTypes.KIND_NUMBER;
    unseeded.locale = 'zz-ZZ';

    IdpConfigLoader.RawRule rule = rawRule(
      'Locale_Rule',
      'Header',
      'a',
      'Case',
      'Subject'
    );
    rule.valueTypeName = 'Bad_Locale';

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{
        rawSection('Header', 'Fixed', 'Case')
      },
      new List<IdpConfigLoader.RawRule>{ rule },
      new Map<String, IdpValueTypes.Config>{ 'Bad_Locale' => unseeded }
    );
    Assert.areEqual(1, config.issues.size());
    Assert.isTrue(
      config.issues[0].message.contains('zz-ZZ'),
      'the admin is told which locale, at load time, not per document'
    );
    Assert.areEqual(
      1,
      config.sections[0].rules.size(),
      'an unseeded locale degrades the parse, it does not stop the rule'
    );
  }

  @IsTest
  static void reportsMonthNamesALanguageCannotRead() {
    IdpValueTypes.Config vietnamese = new IdpValueTypes.Config();
    vietnamese.name = 'VN_Long_Date';
    vietnamese.kind = IdpValueTypes.KIND_DATE;
    vietnamese.locale = 'vi-VN';
    vietnamese.formats = new List<String>{ 'dd MMMM yyyy' };

    IdpConfigLoader.RawRule rule = rawRule(
      'Date_Rule',
      'Header',
      'a',
      'Case',
      'Subject'
    );
    rule.valueTypeName = 'VN_Long_Date';

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{
        rawSection('Header', 'Fixed', 'Case')
      },
      new List<IdpConfigLoader.RawRule>{ rule },
      new Map<String, IdpValueTypes.Config>{ 'VN_Long_Date' => vietnamese }
    );
    Assert.areEqual(1, config.issues.size());
    Assert.isTrue(config.issues[0].message.contains('Month Names'));

    // A language that does declare them says nothing.
    vietnamese.name = 'DE_Long_Date';
    vietnamese.locale = 'de-DE';
    rule.valueTypeName = 'DE_Long_Date';
    IdpConfigLoader.SetConfig german = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{
        rawSection('Header', 'Fixed', 'Case')
      },
      new List<IdpConfigLoader.RawRule>{ rule },
      new Map<String, IdpValueTypes.Config>{ 'DE_Long_Date' => vietnamese }
    );
    Assert.areEqual(0, german.issues.size());
  }

  @IsTest
  static void parsesGradeModeAndPolicyFields() {
    IdpConfigLoader.RawRule strict = rawRule(
      'Strict_Rule',
      'Header',
      'x',
      'Case',
      'Description'
    );
    strict.minGrade = 'Exact';
    strict.mode = 'Compliance';
    strict.required = true;
    strict.minConfidence = 0.9;

    IdpConfigLoader.RawRule badMode = rawRule(
      'Bad_Mode',
      'Header',
      'y',
      'Case',
      'Subject'
    );
    badMode.mode = 'Sideways';

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{
        rawSection('Header', 'Fixed', 'Case')
      },
      new List<IdpConfigLoader.RawRule>{ strict, badMode },
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(1, config.sections[0].rules.size());
    IdpConfigLoader.RuleConfig rule = config.sections[0].rules[0];
    Assert.areEqual(IdpResult.Grade.EXACT, rule.minGrade);
    Assert.areEqual('Compliance', rule.mode);
    Assert.isTrue(rule.required);
    Assert.areEqual(0.9, rule.minConfidence);
    Assert.isTrue(config.issues[0].message.contains('Sideways'));
  }

  @IsTest
  static void mapsValueTypeRecordToConfig() {
    IDP_Value_Type__mdt record = new IDP_Value_Type__mdt(
      DeveloperName = 'Date_Long',
      Kind__c = 'Date',
      Formats__c = 'dd MMMM yyyy|dd/MM/yyyy',
      Output_Format__c = 'yyyy-MM-dd',
      Pivot_Year__c = 1960
    );
    IdpValueTypes.Config cfg = IdpConfigLoader.toConfig(record);
    Assert.areEqual('Date_Long', cfg.name);
    Assert.areEqual(
      new List<String>{ 'dd MMMM yyyy', 'dd/MM/yyyy' },
      cfg.formats
    );
    Assert.areEqual('dd MMMM yyyy|dd/MM/yyyy', cfg.formatsRaw);
    Assert.areEqual(1960, cfg.pivotYear);
  }
}
