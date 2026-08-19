/**
 * Unit tests for config assembly and validation. Two levels are covered:
 * the Raw* DTO level, where misconfiguration must degrade to issues while
 * the rest of the set still runs, and the JSON level, where a hand-edited
 * Definition must parse — or fail loudly enough that an admin can fix it.
 *
 * Custom metadata cannot be inserted in tests, so the set record itself is
 * hand-built; the query→raw mapping is mechanical.
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
    String jsonPath,
    String targetField
  ) {
    IdpConfigLoader.RawRule raw = new IdpConfigLoader.RawRule();
    raw.name = name;
    raw.label = name;
    raw.jsonPath = jsonPath;
    raw.targetField = targetField;
    return raw;
  }

  /** Assembles from Raw sections, skipping the JSON round trip. */
  private static IdpConfigLoader.SetConfig assemble(
    IdpConfigLoader.RawSet mappingSet,
    List<IdpConfigLoader.RawSection> sections,
    Map<String, IdpValueTypes.Config> valueTypes
  ) {
    return IdpConfigLoader.assemble(
      mappingSet,
      JSON.serialize(new Map<String, Object>{ 'sections' => sections }),
      valueTypes
    );
  }

  @IsTest
  static void missingSetIsAnError() {
    IdpConfigLoader.SetConfig config = assemble(
      null,
      new List<IdpConfigLoader.RawSection>(),
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.isFalse(config.found);
    Assert.areEqual(1, config.issues.size());
    Assert.areEqual(IdpResult.SEV_ERROR, config.issues[0].severity);
  }

  @IsTest
  static void assemblesValidConfig() {
    IdpConfigLoader.RawSection header = rawSection('Header', 'Fixed', 'Case');
    header.rules.add(rawRule('Name_Rule', 'applicant.name', 'SuppliedName'));

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ header },
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
  static void unknownObjectSkipsTheSection() {
    IdpConfigLoader.RawSection bad = rawSection('Ghost', 'Fixed', 'No_Such__c');
    bad.rules.add(rawRule('Orphan', 'x', 'Name'));
    IdpConfigLoader.RawSection good = rawSection('Header', 'Fixed', 'Case');
    good.rules.add(rawRule('Good_Rule', 'y', 'Description'));

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ bad, good },
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(1, config.sections.size(), 'one section survives');
    Assert.areEqual('Header', config.sections[0].name);
    Assert.areEqual(1, config.issues.size());
    Assert.isTrue(
      config.issues[0].message.contains('No_Such__c'),
      'the schema check replaces the old EntityDefinition relationship'
    );
  }

  @IsTest
  static void unknownFieldSkipsTheRule() {
    IdpConfigLoader.RawSection header = rawSection('Header', 'Fixed', 'Case');
    header.rules.add(rawRule('Bad_Rule', 'x', 'Not_A_Field__c'));
    header.rules.add(rawRule('Good_Rule', 'y', 'Description'));

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ header },
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(1, config.sections[0].rules.size(), 'one rule survives');
    Assert.areEqual('Good_Rule', config.sections[0].rules[0].name);
    Assert.areEqual(1, config.issues.size());
    Assert.isTrue(config.issues[0].message.contains('Not_A_Field__c'));
  }

  @IsTest
  static void acceptsObjectQualifiedFieldNames() {
    IdpConfigLoader.RawSection header = rawSection('Header', 'Fixed', 'Case');
    header.rules.add(rawRule('Qualified', 'x', 'Case.SuppliedEmail'));

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ header },
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(0, config.issues.size(), 'issues: ' + config.issues);
    Assert.areEqual(
      'SuppliedEmail',
      config.sections[0].rules[0].targetField,
      'the object prefix is stripped for every downstream consumer'
    );
  }

  @IsTest
  static void incompleteRepeatingSectionIsSkippedWithItsRules() {
    IdpConfigLoader.RawSection lines = rawSection(
      'Lines',
      'Repeating',
      'Asset'
    );
    lines.rules.add(rawRule('Line_Rule', 'Quantity', 'Quantity'));

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ lines }, // no row path/match config
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(0, config.sections.size());
    Assert.areEqual(1, config.issues.size(), 'the rules go with the section');
  }

  @IsTest
  static void repeatingSectionWithUnknownMatchFieldIsSkipped() {
    IdpConfigLoader.RawSection lines = rawSection(
      'Lines',
      'Repeating',
      'Asset'
    );
    lines.rowPath = 'Details';
    lines.matchField = 'Not_A_Field__c';
    lines.matchValue = '{row:number}';

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ lines },
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(0, config.sections.size());
    Assert.isTrue(config.issues[0].message.contains('Not_A_Field__c'));
  }

  @IsTest
  static void inactiveSectionsAndRulesAreSkipped() {
    IdpConfigLoader.RawSection off = rawSection('Off', 'Fixed', 'Case');
    off.active = false;
    off.rules.add(rawRule('Never', 'x', 'Description'));

    IdpConfigLoader.RawSection header = rawSection('Header', 'Fixed', 'Case');
    IdpConfigLoader.RawRule disabled = rawRule('Disabled', 'y', 'Subject');
    disabled.active = false;
    header.rules.add(disabled);
    header.rules.add(rawRule('Live', 'z', 'Description'));

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ off, header },
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(1, config.sections.size());
    Assert.areEqual(1, config.sections[0].rules.size());
    Assert.areEqual('Live', config.sections[0].rules[0].name);
    Assert.areEqual(
      0,
      config.issues.size(),
      'deliberately disabling something is not a problem to report'
    );
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
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.isNull(config.sections[0].parentSectionName);
    Assert.areEqual(1, config.issues.size());
  }

  @IsTest
  static void unknownValueTypeSkipsTheRule() {
    IdpConfigLoader.RawRule rule = rawRule('Typed_Rule', 'x', 'Description');
    rule.valueTypeName = 'No_Such_Type';
    IdpConfigLoader.RawSection header = rawSection('Header', 'Fixed', 'Case');
    header.rules.add(rule);

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ header },
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

    IdpConfigLoader.RawRule rule = rawRule('Custom_Rule', 'x', 'Description');
    rule.valueTypeName = 'Broken_Custom';
    IdpConfigLoader.RawSection header = rawSection('Header', 'Fixed', 'Case');
    header.rules.add(rule);

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ header },
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

    IdpConfigLoader.RawRule regexRule = rawRule('Regex_Rule', 'a', 'Subject');
    regexRule.valueTypeName = 'Bad_Regex';
    IdpConfigLoader.RawRule phoneRule = rawRule(
      'Phone_Rule',
      'b',
      'SuppliedPhone'
    );
    phoneRule.valueTypeName = 'Bad_Region';

    IdpConfigLoader.RawSection header = rawSection('Header', 'Fixed', 'Case');
    header.rules.add(regexRule);
    header.rules.add(phoneRule);

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ header },
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

    IdpConfigLoader.RawRule rule = rawRule('Locale_Rule', 'a', 'Subject');
    rule.valueTypeName = 'Bad_Locale';
    IdpConfigLoader.RawSection header = rawSection('Header', 'Fixed', 'Case');
    header.rules.add(rule);

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ header },
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
    // ZA is seeded so the locale is known, but no "zz" language declares
    // month names — exactly the half-configured case worth reporting.
    IdpValueTypes.Config monthless = new IdpValueTypes.Config();
    monthless.name = 'Unknown_Long_Date';
    monthless.kind = IdpValueTypes.KIND_DATE;
    monthless.locale = 'zz-ZA';
    monthless.formats = new List<String>{ 'dd MMMM yyyy' };

    IdpConfigLoader.RawRule rule = rawRule('Date_Rule', 'a', 'Subject');
    rule.valueTypeName = 'Unknown_Long_Date';
    IdpConfigLoader.RawSection header = rawSection('Header', 'Fixed', 'Case');
    header.rules.add(rule);

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ header },
      new Map<String, IdpValueTypes.Config>{ 'Unknown_Long_Date' => monthless }
    );
    Assert.areEqual(1, config.issues.size());
    Assert.isTrue(config.issues[0].message.contains('Month Names'));

    // A language that does declare them says nothing.
    monthless.name = 'SW_Long_Date';
    monthless.locale = 'sw-KE';
    rule.valueTypeName = 'SW_Long_Date';
    IdpConfigLoader.SetConfig swahili = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ header },
      new Map<String, IdpValueTypes.Config>{ 'SW_Long_Date' => monthless }
    );
    Assert.areEqual(0, swahili.issues.size());
  }

  @IsTest
  static void parsesGradeModeAndPolicyFields() {
    IdpConfigLoader.RawRule strict = rawRule('Strict_Rule', 'x', 'Description');
    strict.minGrade = 'Exact';
    strict.mode = 'Compliance';
    strict.required = true;
    strict.minConfidence = 0.9;

    IdpConfigLoader.RawRule badMode = rawRule('Bad_Mode', 'y', 'Subject');
    badMode.mode = 'Sideways';

    IdpConfigLoader.RawSection header = rawSection('Header', 'Fixed', 'Case');
    header.rules.add(strict);
    header.rules.add(badMode);

    IdpConfigLoader.SetConfig config = assemble(
      rawSet(),
      new List<IdpConfigLoader.RawSection>{ header },
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

  // ───────────────────────── JSON definition ──────────────────────

  @IsTest
  static void parsesAHandWrittenDefinition() {
    String definition =
      '{"sections":[{"name":"Header","label":"Header","sectionType":"Fixed",' +
      '"targetObject":"Case","rules":[{"name":"Email","jsonPath":"applicant.email",' +
      '"targetField":"SuppliedEmail","overwritePolicy":"Always","required":true}]}]}';

    IdpConfigLoader.SetConfig config = IdpConfigLoader.assemble(
      rawSet(),
      definition,
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(0, config.issues.size(), 'issues: ' + config.issues);
    IdpConfigLoader.RuleConfig rule = config.sections[0].rules[0];
    Assert.areEqual('SuppliedEmail', rule.targetField);
    Assert.areEqual('Always', rule.overwritePolicy);
    Assert.isTrue(rule.required);
  }

  @IsTest
  static void unreadableDefinitionIsReportedNotThrown() {
    IdpConfigLoader.SetConfig config = IdpConfigLoader.assemble(
      rawSet(),
      '{"sections": [ {"name": "Header",, ] }',
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.isTrue(
      config.found,
      'the set exists even when its JSON does not parse'
    );
    Assert.areEqual(0, config.sections.size());
    Assert.areEqual(1, config.issues.size());
    Assert.areEqual(IdpResult.SEV_ERROR, config.issues[0].severity);
    Assert.isTrue(
      config.issues[0].message.contains('IDP_CONFIGURATION.md'),
      'the message points the admin at the format'
    );
  }

  @IsTest
  static void misspelledKeyIsReportedNotSilentlyIgnored() {
    // "jsonPaths" is not a key. JSON.deserialize would ignore it and leave
    // a rule that maps nothing, so the loader screens keys first — this is
    // the check that turns an admin's typo into a message.
    IdpConfigLoader.SetConfig config = IdpConfigLoader.assemble(
      rawSet(),
      '{"sections":[{"name":"Header","targetObject":"Case","rules":' +
      '[{"name":"R","jsonPaths":"a","targetField":"Subject"}]}]}',
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(1, config.issues.size());
    Assert.areEqual(IdpResult.SEV_ERROR, config.issues[0].severity);
    Assert.isTrue(
      config.issues[0].message.contains('jsonPaths'),
      'the admin is told which key, and on which rule: ' +
      config.issues[0].message
    );
    Assert.areEqual(
      0,
      config.sections.size(),
      'nothing loads, because a partly-understood definition is not honest'
    );
  }

  @IsTest
  static void unknownSectionKeyIsAlsoReported() {
    IdpConfigLoader.SetConfig config = IdpConfigLoader.assemble(
      rawSet(),
      '{"sections":[{"name":"Header","targetObjekt":"Case","rules":[]}]}',
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(1, config.issues.size());
    Assert.isTrue(config.issues[0].message.contains('targetObjekt'));
  }

  @IsTest
  static void emptyDefinitionIsAWarning() {
    IdpConfigLoader.SetConfig config = IdpConfigLoader.assemble(
      rawSet(),
      null,
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.isTrue(config.found);
    Assert.areEqual(0, config.sections.size());
    Assert.areEqual(1, config.issues.size());
    Assert.areEqual(IdpResult.SEV_WARNING, config.issues[0].severity);
  }

  // ─────────────────────────── value types ────────────────────────

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
    Assert.areEqual(0, cfg.mapEntries.size());
  }

  @IsTest
  static void parsesValueMapEntries() {
    List<IdpValueTypes.MapEntry> entries = IdpConfigLoader.parseMapEntries(
      '{"entries":[' +
        '{"fromText":"Pty Ltd","toValue":"Private Company"},' +
        '{"fromText":"(?i)cc","toValue":"Close Corporation","matchStyle":"Regex"},' +
        '{"fromText":"Old","toValue":"Gone","active":false}]}'
    );
    Assert.areEqual(2, entries.size(), 'the inactive entry is dropped');
    Assert.areEqual(
      'Normalized',
      entries[0].matchStyle,
      'an unstated style keeps the MapEntry default'
    );
    Assert.areEqual('Regex', entries[1].matchStyle);
  }

  @IsTest
  static void brokenValueMapYieldsNoEntries() {
    Assert.areEqual(
      0,
      IdpConfigLoader.parseMapEntries('{"entries":[').size(),
      'a broken dictionary maps nothing rather than mapping wrongly'
    );
    Assert.areEqual(0, IdpConfigLoader.parseMapEntries(null).size());
  }
}
