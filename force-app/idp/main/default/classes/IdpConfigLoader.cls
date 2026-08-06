/**
 * Loads one mapping set's configuration — set, sections, rules, value
 * types and value map entries — into plain Apex DTOs, validating as it
 * goes. Configuration problems never throw: each one becomes a
 * CONFIG_ISSUE finding on SetConfig.issues, the offending piece is
 * disabled, and the rest of the set still runs.
 *
 * Custom metadata SOQL does not count against query limits, and the
 * assembled config is cached for the transaction.
 *
 * Structure: query...() methods map SOQL rows to Raw* DTOs (thin,
 * mechanical), assemble() turns Raw* into validated SetConfig. Tests
 * exercise assemble() directly with hand-built Raw* records, because
 * custom metadata cannot be inserted in a test context.
 */
public inherited sharing class IdpConfigLoader {
  /** Per-transaction cache; tests prime it with assembled configs. */
  @TestVisible
  private static Map<String, SetConfig> cache = new Map<String, SetConfig>();

  // ────────────────────────── public DTOs ─────────────────────────

  public class SetConfig {
    public Boolean found = false;
    public String name;
    public String label;
    public String defaultMode;
    public String jsonSourceField;
    public String processedMarkerField;
    public String findingHandler;
    public List<SectionConfig> sections = new List<SectionConfig>();
    public List<IdpResult.Finding> issues = new List<IdpResult.Finding>();
  }

  public class SectionConfig {
    public String name; // DeveloperName — the section's identity
    public String label;
    public Boolean repeating = false;
    public String targetObject;
    public String rowPath;
    public String matchField;
    public String matchValue;
    public String recordFilter;
    public String parentSectionName;
    public List<RuleConfig> rules = new List<RuleConfig>();
  }

  public class RuleConfig {
    public String name;
    public String label;
    public String jsonPath;
    public String targetObject;
    public String targetField;
    public String mode; // blank inherits the run's
    public String overwritePolicy;
    public IdpResult.Grade minGrade = IdpResult.Grade.INFERRED;
    public Decimal minConfidence;
    public Boolean required = false;
    public String anchorFilter;
    /** Explicit value type; null means auto-derive from the target field. */
    public IdpValueTypes.Config typeConfig;
    public IValueType type;
  }

  // ─────────────────────────── raw DTOs ───────────────────────────

  public class RawSet {
    public String name;
    public String label;
    public String defaultMode;
    public String jsonSourceField;
    public String processedMarkerField;
    public String findingHandler;
    public Boolean active = true;
  }

  public class RawSection {
    public String name;
    public String label;
    public String sectionType;
    public String targetObject;
    public String rowPath;
    public String matchField;
    public String matchValue;
    public String recordFilter;
    public String parentSection;
  }

  public class RawRule {
    public String name;
    public String label;
    public String sectionName;
    public String jsonPath;
    public String targetObject;
    public String targetField;
    public String valueTypeName;
    public String mode;
    public String overwritePolicy;
    public String minGrade;
    public Decimal minConfidence;
    public Boolean required = false;
    public String anchorFilter;
  }

  // ───────────────────────────── load ─────────────────────────────

  public static SetConfig load(String mappingSetName) {
    String key = mappingSetName == null ? '' : mappingSetName;
    if (!cache.containsKey(key)) {
      cache.put(
        key,
        assemble(
          querySet(mappingSetName),
          querySections(mappingSetName),
          queryRules(mappingSetName),
          new Map<String, IdpValueTypes.Config>() // filled inside assemble via loadValueTypes
        )
      );
    }
    return cache.get(key);
  }

  /** Assembles and validates. valueTypes may be pre-supplied (tests);
   *  names it lacks are loaded from the org. */
  @TestVisible
  private static SetConfig assemble(
    RawSet rawSet,
    List<RawSection> rawSections,
    List<RawRule> rawRules,
    Map<String, IdpValueTypes.Config> valueTypes
  ) {
    SetConfig config = new SetConfig();
    if (rawSet == null || rawSet.active != true) {
      issue(
        config,
        IdpResult.SEV_ERROR,
        'No active IDP Mapping Set was found for this name.'
      );
      return config;
    }
    config.found = true;
    config.name = rawSet.name;
    config.label = rawSet.label;
    config.defaultMode = rawSet.defaultMode;
    config.jsonSourceField = rawSet.jsonSourceField;
    config.processedMarkerField = rawSet.processedMarkerField;
    config.findingHandler = rawSet.findingHandler;

    Map<String, SectionConfig> sectionsByName = new Map<String, SectionConfig>();
    for (RawSection raw : rawSections) {
      SectionConfig section = assembleSection(raw, config);
      if (section != null) {
        sectionsByName.put(section.name, section);
        config.sections.add(section);
      }
    }
    // Parent references must point at surviving sections.
    for (SectionConfig section : config.sections) {
      if (
        String.isNotBlank(section.parentSectionName) &&
        !sectionsByName.containsKey(section.parentSectionName)
      ) {
        issue(
          config,
          IdpResult.SEV_WARNING,
          'Section ' +
            section.name +
            ' names unknown or inactive parent section "' +
            section.parentSectionName +
            '"; the parent constraint was dropped.'
        );
        section.parentSectionName = null;
      }
    }

    loadReferencedValueTypes(rawRules, valueTypes);
    for (RawRule raw : rawRules) {
      assembleRule(raw, sectionsByName, valueTypes, config);
    }
    return config;
  }

  private static SectionConfig assembleSection(
    RawSection raw,
    SetConfig config
  ) {
    SectionConfig section = new SectionConfig();
    section.name = raw.name;
    section.label = raw.label;
    section.repeating = raw.sectionType == 'Repeating';
    section.targetObject = raw.targetObject;
    section.rowPath = raw.rowPath;
    section.matchField = raw.matchField;
    section.matchValue = raw.matchValue;
    section.recordFilter = raw.recordFilter;
    section.parentSectionName = raw.parentSection;

    if (String.isBlank(section.targetObject)) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Section ' + raw.name + ' has no Target Object and was skipped.'
      );
      return null;
    }
    if (
      section.repeating &&
      (String.isBlank(section.rowPath) ||
      String.isBlank(section.matchField) ||
      String.isBlank(section.matchValue))
    ) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Repeating section ' +
          raw.name +
          ' needs Row Path, Match Field and Match Value; it was skipped.'
      );
      return null;
    }
    return section;
  }

  private static void assembleRule(
    RawRule raw,
    Map<String, SectionConfig> sectionsByName,
    Map<String, IdpValueTypes.Config> valueTypes,
    SetConfig config
  ) {
    SectionConfig section = sectionsByName.get(raw.sectionName);
    if (section == null) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Rule ' +
          raw.name +
          ' points at unknown, inactive or skipped section "' +
          raw.sectionName +
          '"; the rule was skipped.'
      );
      return;
    }
    if (String.isBlank(raw.jsonPath) || String.isBlank(raw.targetField)) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Rule ' +
          raw.name +
          ' needs both a JSON Path and a Target Field; it was skipped.'
      );
      return;
    }
    if (
      String.isNotBlank(raw.targetObject) &&
      raw.targetObject != section.targetObject
    ) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Rule ' +
          raw.name +
          ' targets ' +
          raw.targetObject +
          ' but its section ' +
          section.name +
          ' targets ' +
          section.targetObject +
          '; the rule was skipped.'
      );
      return;
    }
    if (
      String.isNotBlank(raw.mode) &&
      raw.mode != IdpMappingEngine.MODE_EXTRACTION &&
      raw.mode != IdpMappingEngine.MODE_COMPLIANCE
    ) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Rule ' +
          raw.name +
          ' has unknown Mode "' +
          raw.mode +
          '"; the rule was skipped.'
      );
      return;
    }

    RuleConfig rule = new RuleConfig();
    rule.name = raw.name;
    rule.label = raw.label;
    rule.jsonPath = raw.jsonPath;
    rule.targetObject = section.targetObject;
    rule.targetField = raw.targetField;
    rule.mode = raw.mode;
    rule.overwritePolicy = raw.overwritePolicy;
    rule.minGrade = raw.minGrade == 'Exact'
      ? IdpResult.Grade.EXACT
      : IdpResult.Grade.INFERRED;
    rule.minConfidence = raw.minConfidence;
    rule.required = raw.required == true;
    rule.anchorFilter = raw.anchorFilter;

    if (String.isNotBlank(raw.valueTypeName)) {
      IdpValueTypes.Config typeConfig = valueTypes.get(raw.valueTypeName);
      if (typeConfig == null) {
        issue(
          config,
          IdpResult.SEV_WARNING,
          'Rule ' +
            raw.name +
            ' names unknown value type "' +
            raw.valueTypeName +
            '"; the rule was skipped.'
        );
        return;
      }
      try {
        rule.type = IdpTypeRegistry.resolve(typeConfig);
        rule.typeConfig = typeConfig;
        validateTypeConfig(typeConfig, config);
      } catch (IdpValueTypes.TypeException e) {
        issue(
          config,
          IdpResult.SEV_WARNING,
          'Rule ' + raw.name + ': ' + e.getMessage() + ' The rule was skipped.'
        );
        return;
      }
    }
    section.rules.add(rule);
  }

  /** Load-time checks that make config typos visible before a document
   *  ever runs: regex patterns must compile, regions and timezones must
   *  be known. */
  private static void validateTypeConfig(
    IdpValueTypes.Config typeConfig,
    SetConfig config
  ) {
    if (typeConfig.kind == IdpValueTypes.KIND_REGEX) {
      try {
        Pattern.compile(typeConfig.formatsRaw == null ? '' : typeConfig.formatsRaw);
      } catch (Exception e) {
        issue(
          config,
          IdpResult.SEV_WARNING,
          'Value type ' +
            typeConfig.name +
            ' has an invalid regex in Formats: ' +
            e.getMessage()
        );
      }
    }
    for (IdpValueTypes.MapEntry entry : typeConfig.mapEntries) {
      if (entry.matchStyle == 'Regex') {
        try {
          Pattern.compile(entry.fromText);
        } catch (Exception e) {
          issue(
            config,
            IdpResult.SEV_WARNING,
            'Value map ' +
              typeConfig.name +
              ' entry "' +
              entry.fromText +
              '" is not a valid regex: ' +
              e.getMessage()
          );
        }
      }
    }
    if (
      String.isNotBlank(typeConfig.currencyCode) &&
      !IdpValueTypes.isKnownCurrency(typeConfig.currencyCode)
    ) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Value type ' +
          typeConfig.name +
          ' has unknown Currency "' +
          typeConfig.currencyCode +
          '"; it is not a recognized ISO 4217 code.'
      );
    }
    if (
      String.isNotBlank(typeConfig.region) &&
      IdpValueTypes.dialCodeFor(typeConfig.region) == null
    ) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Value type ' +
          typeConfig.name +
          ' has unknown Region "' +
          typeConfig.region +
          '"; phone numbers will parse as digits only.'
      );
    }
    if (
      String.isNotBlank(typeConfig.timezone) &&
      typeConfig.timezone != 'GMT' &&
      TimeZone.getTimeZone(typeConfig.timezone).getID() == 'GMT'
    ) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Value type ' +
          typeConfig.name +
          ' has unknown Timezone "' +
          typeConfig.timezone +
          '"; timestamps will be read as GMT.'
      );
    }
  }

  private static void issue(
    SetConfig config,
    String severity,
    String message
  ) {
    IdpResult.Finding finding = new IdpResult.Finding();
    finding.code = IdpResult.CODE_CONFIG_ISSUE;
    finding.severity = severity;
    finding.message = message;
    config.issues.add(finding);
  }

  // ──────────────────────────── queries ───────────────────────────

  private static RawSet querySet(String mappingSetName) {
    List<IDP_Mapping_Set__mdt> records = [
      SELECT
        DeveloperName,
        MasterLabel,
        Default_Mode__c,
        JSON_Source_Field__c,
        Processed_Marker_Field__c,
        Finding_Handler__c,
        Active__c
      FROM IDP_Mapping_Set__mdt
      WHERE DeveloperName = :mappingSetName
      LIMIT 1
    ];
    if (records.isEmpty()) {
      return null;
    }
    RawSet raw = new RawSet();
    raw.name = records[0].DeveloperName;
    raw.label = records[0].MasterLabel;
    raw.defaultMode = records[0].Default_Mode__c;
    raw.jsonSourceField = records[0].JSON_Source_Field__c;
    raw.processedMarkerField = records[0].Processed_Marker_Field__c;
    raw.findingHandler = records[0].Finding_Handler__c;
    raw.active = records[0].Active__c;
    return raw;
  }

  private static List<RawSection> querySections(String mappingSetName) {
    List<RawSection> raws = new List<RawSection>();
    for (IDP_Section__mdt record : [
      SELECT
        DeveloperName,
        MasterLabel,
        Section_Type__c,
        Target_Object__r.QualifiedApiName,
        Row_Path__c,
        Match_Field__r.QualifiedApiName,
        Match_Value__c,
        Record_Filter__c,
        Parent_Section__c
      FROM IDP_Section__mdt
      WHERE
        Mapping_Set__r.DeveloperName = :mappingSetName
        AND Active__c = TRUE
      ORDER BY DeveloperName
    ]) {
      RawSection raw = new RawSection();
      raw.name = record.DeveloperName;
      raw.label = record.MasterLabel;
      raw.sectionType = record.Section_Type__c;
      raw.targetObject = record.Target_Object__r?.QualifiedApiName;
      raw.rowPath = record.Row_Path__c;
      raw.matchField = record.Match_Field__r?.QualifiedApiName;
      raw.matchValue = record.Match_Value__c;
      raw.recordFilter = record.Record_Filter__c;
      raw.parentSection = record.Parent_Section__c;
      raws.add(raw);
    }
    return raws;
  }

  private static List<RawRule> queryRules(String mappingSetName) {
    List<RawRule> raws = new List<RawRule>();
    for (IDP_Mapping_Rule__mdt record : [
      SELECT
        DeveloperName,
        MasterLabel,
        JSON_Path__c,
        Section__r.DeveloperName,
        Target_Object__r.QualifiedApiName,
        Target_Field__r.QualifiedApiName,
        Value_Type__r.DeveloperName,
        Mode__c,
        Overwrite_Policy__c,
        Min_Grade__c,
        Min_Confidence__c,
        Required__c,
        Anchor_Filter__c
      FROM IDP_Mapping_Rule__mdt
      WHERE
        Section__r.Mapping_Set__r.DeveloperName = :mappingSetName
        AND Active__c = TRUE
      ORDER BY DeveloperName
    ]) {
      RawRule raw = new RawRule();
      raw.name = record.DeveloperName;
      raw.label = record.MasterLabel;
      raw.sectionName = record.Section__r?.DeveloperName;
      raw.jsonPath = record.JSON_Path__c;
      raw.targetObject = record.Target_Object__r?.QualifiedApiName;
      raw.targetField = record.Target_Field__r?.QualifiedApiName;
      raw.valueTypeName = record.Value_Type__r?.DeveloperName;
      raw.mode = record.Mode__c;
      raw.overwritePolicy = record.Overwrite_Policy__c;
      raw.minGrade = record.Min_Grade__c;
      raw.minConfidence = record.Min_Confidence__c;
      raw.required = record.Required__c;
      raw.anchorFilter = record.Anchor_Filter__c;
      raws.add(raw);
    }
    return raws;
  }

  /** One value type with its map entries, for IdpMappingController's
   *  previewValue admin tester. Null when the name is unknown. */
  public static IdpValueTypes.Config loadValueType(String developerName) {
    Map<String, IdpValueTypes.Config> loaded = new Map<String, IdpValueTypes.Config>();
    IdpConfigLoader.RawRule probe = new IdpConfigLoader.RawRule();
    probe.valueTypeName = developerName;
    loadReferencedValueTypes(new List<RawRule>{ probe }, loaded);
    return loaded.get(developerName);
  }

  /** Loads the value types the rules reference (minus any pre-supplied by
   *  a test) together with their map entries. */
  private static void loadReferencedValueTypes(
    List<RawRule> rawRules,
    Map<String, IdpValueTypes.Config> valueTypes
  ) {
    Set<String> needed = new Set<String>();
    for (RawRule raw : rawRules) {
      if (
        String.isNotBlank(raw.valueTypeName) &&
        !valueTypes.containsKey(raw.valueTypeName)
      ) {
        needed.add(raw.valueTypeName);
      }
    }
    if (needed.isEmpty()) {
      return;
    }
    for (IDP_Value_Type__mdt record : [
      SELECT
        DeveloperName,
        Kind__c,
        Handler_Class__c,
        Locale__c,
        Currency__c,
        Formats__c,
        Output_Format__c,
        Region__c,
        Scale_Factor__c,
        Compare_Tolerance__c,
        Pivot_Year__c,
        Timezone__c,
        Custom_Options__c
      FROM IDP_Value_Type__mdt
      WHERE DeveloperName IN :needed
    ]) {
      valueTypes.put(record.DeveloperName, toConfig(record));
    }
    for (IDP_Value_Map_Entry__mdt record : [
      SELECT
        Value_Map__r.DeveloperName,
        From_Text__c,
        To_Value__c,
        Match_Style__c
      FROM IDP_Value_Map_Entry__mdt
      WHERE Value_Map__r.DeveloperName IN :needed AND Active__c = TRUE
      ORDER BY DeveloperName
    ]) {
      IdpValueTypes.Config owner = valueTypes.get(
        record.Value_Map__r.DeveloperName
      );
      if (owner == null) {
        continue;
      }
      IdpValueTypes.MapEntry entry = new IdpValueTypes.MapEntry();
      entry.fromText = record.From_Text__c;
      entry.toValue = record.To_Value__c;
      if (String.isNotBlank(record.Match_Style__c)) {
        entry.matchStyle = record.Match_Style__c;
      }
      owner.mapEntries.add(entry);
    }
  }

  @TestVisible
  private static IdpValueTypes.Config toConfig(IDP_Value_Type__mdt record) {
    IdpValueTypes.Config cfg = new IdpValueTypes.Config();
    cfg.name = record.DeveloperName;
    cfg.kind = record.Kind__c;
    cfg.handlerClass = record.Handler_Class__c;
    cfg.locale = record.Locale__c;
    cfg.currencyCode = record.Currency__c;
    cfg.formatsRaw = record.Formats__c;
    if (String.isNotBlank(record.Formats__c)) {
      for (String format : record.Formats__c.split('\\|')) {
        if (String.isNotBlank(format)) {
          cfg.formats.add(format.trim());
        }
      }
    }
    cfg.outputFormat = record.Output_Format__c;
    cfg.region = record.Region__c;
    cfg.scaleFactor = record.Scale_Factor__c;
    cfg.compareTolerance = record.Compare_Tolerance__c;
    cfg.pivotYear = record.Pivot_Year__c == null
      ? null
      : record.Pivot_Year__c.intValue();
    cfg.timezone = record.Timezone__c;
    cfg.customOptions = record.Custom_Options__c;
    return cfg;
  }
}
