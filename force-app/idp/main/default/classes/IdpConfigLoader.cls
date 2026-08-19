/**
 * Loads one mapping set's configuration — set, sections, rules, value
 * types and value map entries — into plain Apex DTOs, validating as it
 * goes. Configuration problems never throw: each one becomes a
 * CONFIG_ISSUE finding on SetConfig.issues, the offending piece is
 * disabled, and the rest of the set still runs.
 *
 * Sections and rules live as JSON in IDP_Mapping_Set__mdt.Definition__c,
 * and a ValueMap's entries as JSON in IDP_Value_Type__mdt.
 * Value_Map_Entries__c. A long text area costs a flat 255 characters
 * against the org's custom metadata allocation however much it holds,
 * where the same content as records cost roughly 22,000 characters per
 * document model — and that allocation is shared across the whole org.
 * See IDP_CONFIGURATION.md for the JSON format.
 *
 * Because the JSON carries no FieldDefinition relationship, the object
 * and field names it uses are checked against the real schema here, at
 * load time, so a typo becomes a finding rather than a runtime failure.
 *
 * Custom metadata SOQL does not count against query limits, and the
 * assembled config is cached for the transaction.
 *
 * Structure: querySet() and parseDefinition() produce Raw* DTOs (thin,
 * mechanical), assemble() turns Raw* into validated SetConfig. The Raw*
 * shapes are the JSON contract — their field names are the JSON keys.
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
  // These double as the JSON contract: every public field below is a key
  // an admin may write in Definition__c or Value_Map_Entries__c.

  public class RawSet {
    public String name;
    public String label;
    public String defaultMode;
    public String jsonSourceField;
    public String processedMarkerField;
    public String findingHandler;
    public String definitionJson;
    public Boolean active = true;
  }

  /** Root of Definition__c. */
  public class RawDefinition {
    public List<RawSection> sections = new List<RawSection>();
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
    public Boolean active = true;
    public List<RawRule> rules = new List<RawRule>();
  }

  public class RawRule {
    public String name;
    public String label;
    public String jsonPath;
    public String targetField;
    public String valueTypeName;
    public String mode;
    public String overwritePolicy;
    public String minGrade;
    public Decimal minConfidence;
    public Boolean required = false;
    public String anchorFilter;
    public Boolean active = true;
  }

  /** Root of Value_Map_Entries__c. */
  public class RawValueMap {
    public List<RawMapEntry> entries = new List<RawMapEntry>();
  }

  public class RawMapEntry {
    public String fromText;
    public String toValue;
    public String matchStyle;
    public Boolean active = true;
  }

  // ───────────────────────────── load ─────────────────────────────

  public static SetConfig load(String mappingSetName) {
    String key = mappingSetName == null ? '' : mappingSetName;
    if (!cache.containsKey(key)) {
      RawSet rawSet = querySet(mappingSetName);
      cache.put(
        key,
        assemble(
          rawSet,
          rawSet == null ? null : rawSet.definitionJson,
          new Map<String, IdpValueTypes.Config>()
        )
      ); // filled inside assemble
    }
    return cache.get(key);
  }

  /**
   * Validates a Definition without caching it or touching the set record,
   * so the configurator's Check button runs exactly the code that a real
   * run would. Returns the issues it would raise; an empty list means the
   * definition loads cleanly.
   */
  public static List<IdpResult.Finding> validateDefinition(
    String mappingSetName,
    String definitionJson
  ) {
    RawSet probe = new RawSet();
    probe.name = String.isBlank(mappingSetName) ? 'Draft' : mappingSetName;
    probe.label = probe.name;
    return assemble(
        probe,
        definitionJson,
        new Map<String, IdpValueTypes.Config>()
      )
      .issues;
  }

  /**
   * Assembles and validates. definitionJson is the raw Definition__c text;
   * valueTypes may be pre-supplied (tests), and any name it lacks is
   * loaded from the org.
   */
  @TestVisible
  private static SetConfig assemble(
    RawSet rawSet,
    String definitionJson,
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

    return assembleSections(
      parseDefinition(definitionJson, config),
      valueTypes,
      config
    );
  }

  /** The Raw* half of assemble(), so tests can drive it with hand-built
   *  sections instead of serializing to JSON first. */
  @TestVisible
  private static SetConfig assembleSections(
    List<RawSection> rawSections,
    Map<String, IdpValueTypes.Config> valueTypes,
    SetConfig config
  ) {
    Map<String, SectionConfig> sectionsByName = new Map<String, SectionConfig>();
    List<RawSection> kept = new List<RawSection>();
    for (RawSection raw : rawSections) {
      if (raw == null || raw.active == false) {
        continue;
      }
      SectionConfig section = assembleSection(raw, config);
      if (section != null) {
        sectionsByName.put(section.name, section);
        config.sections.add(section);
        kept.add(raw);
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

    loadReferencedValueTypes(kept, valueTypes);
    for (RawSection raw : kept) {
      SectionConfig section = sectionsByName.get(raw.name);
      if (raw.rules == null) {
        continue;
      }
      for (RawRule rule : raw.rules) {
        if (rule != null && rule.active != false) {
          assembleRule(rule, section, valueTypes, config);
        }
      }
    }
    return config;
  }

  /** Definition__c text into Raw sections. A malformed document disables
   *  the whole set rather than half of it, which is the honest outcome —
   *  there is no way to tell which rules a broken parse swallowed. */
  @TestVisible
  private static List<RawSection> parseDefinition(
    String definitionJson,
    SetConfig config
  ) {
    if (String.isBlank(definitionJson)) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Mapping set ' +
          config.name +
          ' has an empty Definition, so it maps nothing. See IDP_CONFIGURATION.md for the format.'
      );
      return new List<RawSection>();
    }
    if (!keysAreKnown(definitionJson, config)) {
      return new List<RawSection>();
    }
    try {
      RawDefinition parsed = (RawDefinition) JSON.deserialize(
        definitionJson,
        RawDefinition.class
      );
      if (parsed == null || parsed.sections == null) {
        issue(
          config,
          IdpResult.SEV_ERROR,
          'Mapping set ' +
            config.name +
            ' has a Definition with no "sections" list; nothing was loaded.'
        );
        return new List<RawSection>();
      }
      return parsed.sections;
    } catch (Exception e) {
      issue(
        config,
        IdpResult.SEV_ERROR,
        'Mapping set ' +
          config.name +
          ' has an unreadable Definition and was not loaded: ' +
          e.getMessage() +
          ' Check for a misspelled key or a JSON syntax error; see IDP_CONFIGURATION.md.'
      );
      return new List<RawSection>();
    }
  }

  private static final Set<String> SECTION_KEYS = new Set<String>{
    'name',
    'label',
    'sectionType',
    'targetObject',
    'rowPath',
    'matchField',
    'matchValue',
    'recordFilter',
    'parentSection',
    'active',
    'rules'
  };

  private static final Set<String> RULE_KEYS = new Set<String>{
    'name',
    'label',
    'jsonPath',
    'targetField',
    'valueTypeName',
    'mode',
    'overwritePolicy',
    'minGrade',
    'minConfidence',
    'required',
    'anchorFilter',
    'active'
  };

  /**
   * JSON.deserialize quietly ignores a key it does not recognize, which
   * would turn a misspelled "jsonPaths" into a rule that silently maps
   * nothing. For hand-edited configuration that is the worst possible
   * failure mode, so unknown keys are found and reported before the typed
   * parse runs. Returns false when the definition should not be loaded.
   */
  @TestVisible
  private static Boolean keysAreKnown(String definitionJson, SetConfig config) {
    List<String> unknown = new List<String>();
    try {
      Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(
        definitionJson
      );
      for (String key : root.keySet()) {
        if (key != 'sections') {
          unknown.add(key);
        }
      }
      Object sections = root.get('sections');
      if (sections instanceof List<Object>) {
        for (Object entry : (List<Object>) sections) {
          if (!(entry instanceof Map<String, Object>)) {
            continue;
          }
          Map<String, Object> section = (Map<String, Object>) entry;
          String onSection = ' on section "' + section.get('name') + '"';
          for (String key : section.keySet()) {
            if (!SECTION_KEYS.contains(key)) {
              unknown.add(key + onSection);
            }
          }
          Object rules = section.get('rules');
          if (!(rules instanceof List<Object>)) {
            continue;
          }
          for (Object ruleEntry : (List<Object>) rules) {
            if (!(ruleEntry instanceof Map<String, Object>)) {
              continue;
            }
            Map<String, Object> rule = (Map<String, Object>) ruleEntry;
            for (String key : rule.keySet()) {
              if (!RULE_KEYS.contains(key)) {
                unknown.add(key + ' on rule "' + rule.get('name') + '"');
              }
            }
          }
        }
      }
    } catch (Exception e) {
      return true; // malformed JSON — the typed parse reports it properly
    }
    if (unknown.isEmpty()) {
      return true;
    }
    issue(
      config,
      IdpResult.SEV_ERROR,
      'Mapping set ' +
        config.name +
        ' has ' +
        (unknown.size() == 1 ? 'an unrecognized key' : 'unrecognized keys') +
        ': ' +
        String.join(unknown, ', ') +
        '. Nothing was loaded, because a misspelled key would otherwise map ' +
        'nothing without saying so. See IDP_CONFIGURATION.md for the keys.'
    );
    return false;
  }

  private static SectionConfig assembleSection(
    RawSection raw,
    SetConfig config
  ) {
    SectionConfig section = new SectionConfig();
    section.name = raw.name;
    section.label = String.isBlank(raw.label) ? raw.name : raw.label;
    section.repeating = raw.sectionType == 'Repeating';
    section.targetObject = raw.targetObject;
    section.rowPath = raw.rowPath;
    section.matchField = bareField(raw.matchField);
    section.matchValue = raw.matchValue;
    section.recordFilter = raw.recordFilter;
    section.parentSectionName = raw.parentSection;

    if (String.isBlank(section.name)) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'A section has no name and was skipped; every section needs a unique "name".'
      );
      return null;
    }
    if (String.isBlank(section.targetObject)) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Section ' + section.name + ' has no Target Object and was skipped.'
      );
      return null;
    }
    // The EntityDefinition relationship used to make this impossible; now
    // the schema is the only thing that can say whether the name is real.
    if (IdpSchemaCache.typeOf(section.targetObject) == null) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Section ' +
          section.name +
          ' names unknown object "' +
          section.targetObject +
          '"; the section and its rules were skipped.'
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
          section.name +
          ' needs Row Path, Match Field and Match Value; it was skipped.'
      );
      return null;
    }
    if (
      section.repeating &&
      IdpSchemaCache.field(section.targetObject, section.matchField) == null
    ) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Repeating section ' +
          section.name +
          ' names unknown Match Field "' +
          section.matchField +
          '" on ' +
          section.targetObject +
          '; it was skipped.'
      );
      return null;
    }
    return section;
  }

  private static void assembleRule(
    RawRule raw,
    SectionConfig section,
    Map<String, IdpValueTypes.Config> valueTypes,
    SetConfig config
  ) {
    String ruleName = String.isBlank(raw.name)
      ? '(unnamed, in section ' + section.name + ')'
      : raw.name;
    String targetField = bareField(raw.targetField);

    if (String.isBlank(raw.jsonPath) || String.isBlank(targetField)) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Rule ' +
          ruleName +
          ' needs both a JSON Path and a Target Field; it was skipped.'
      );
      return;
    }
    if (IdpSchemaCache.field(section.targetObject, targetField) == null) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Rule ' +
          ruleName +
          ' names unknown field "' +
          targetField +
          '" on ' +
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
          ruleName +
          ' has unknown Mode "' +
          raw.mode +
          '"; the rule was skipped.'
      );
      return;
    }

    RuleConfig rule = new RuleConfig();
    rule.name = raw.name;
    rule.label = String.isBlank(raw.label) ? raw.name : raw.label;
    rule.jsonPath = raw.jsonPath;
    rule.targetObject = section.targetObject;
    rule.targetField = targetField;
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
            ruleName +
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
          'Rule ' + ruleName + ': ' + e.getMessage() + ' The rule was skipped.'
        );
        return;
      }
    }
    section.rules.add(rule);
  }

  /**
   * Admins reasonably write either "SuppliedEmail" or "Case.SuppliedEmail",
   * because the old FieldDefinition picker showed the qualified form. Every
   * consumer downstream wants the bare name, so accept both here.
   */
  @TestVisible
  private static String bareField(String fieldRef) {
    if (String.isBlank(fieldRef) || !fieldRef.contains('.')) {
      return fieldRef;
    }
    String bare = fieldRef.substringAfterLast('.');
    return String.isBlank(bare) ? fieldRef : bare;
  }

  /** Load-time checks that make config typos visible before a document
   *  ever runs: regex patterns must compile, currencies, regions, locales
   *  and timezones must be known. */
  private static void validateTypeConfig(
    IdpValueTypes.Config typeConfig,
    SetConfig config
  ) {
    if (typeConfig.kind == IdpValueTypes.KIND_REGEX) {
      try {
        Pattern.compile(
          typeConfig.formatsRaw == null ? '' : typeConfig.formatsRaw
        );
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
          '"; no IDP Country record carries a dial code for it, so phone numbers will parse as digits only.'
      );
    }
    validateLocale(typeConfig, config);
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

  /**
   * A Locale is only worth configuring if the org has seeded the country
   * or language it names, so an unseeded one is reported at load time
   * rather than discovered as a silently-degraded parse. A Date type
   * reading month names is checked harder: a language with no month names
   * is the difference between a working Swahili mapping set and one that
   * fails every long-form date.
   */
  private static void validateLocale(
    IdpValueTypes.Config typeConfig,
    SetConfig config
  ) {
    if (String.isBlank(typeConfig.locale)) {
      return;
    }
    if (!IdpLocaleData.isKnownLocale(typeConfig.locale)) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Value type ' +
          typeConfig.name +
          ' has unrecognized Locale "' +
          typeConfig.locale +
          '"; no IDP Language or IDP Country record matches, so number separators fall back to the graded heuristic and month names to English.'
      );
      return;
    }
    if (
      typeConfig.kind == IdpValueTypes.KIND_DATE &&
      readsMonthNames(typeConfig) &&
      !IdpLocaleData.readsMonthNames(typeConfig.locale)
    ) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Value type ' +
          typeConfig.name +
          ' reads month names in Locale "' +
          typeConfig.locale +
          '", but that language has no Month Names; they will be read as English.'
      );
    }
  }

  /** True when any of the type's date patterns contains MMM or MMMM. */
  private static Boolean readsMonthNames(IdpValueTypes.Config typeConfig) {
    for (String format : typeConfig.formats) {
      if (format.contains('MMM')) {
        return true;
      }
    }
    return false;
  }

  private static void issue(SetConfig config, String severity, String message) {
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
        Definition__c,
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
    raw.definitionJson = records[0].Definition__c;
    raw.active = records[0].Active__c;
    return raw;
  }

  /** One value type with its map entries, for IdpMappingController's
   *  previewValue admin tester. Null when the name is unknown. */
  public static IdpValueTypes.Config loadValueType(String developerName) {
    Map<String, IdpValueTypes.Config> loaded = new Map<String, IdpValueTypes.Config>();
    if (String.isNotBlank(developerName)) {
      queryValueTypes(new Set<String>{ developerName }, loaded);
    }
    return loaded.get(developerName);
  }

  /** Loads the value types the rules reference (minus any pre-supplied by
   *  a test) together with their map entries. */
  private static void loadReferencedValueTypes(
    List<RawSection> rawSections,
    Map<String, IdpValueTypes.Config> valueTypes
  ) {
    Set<String> needed = new Set<String>();
    for (RawSection section : rawSections) {
      if (section.rules == null) {
        continue;
      }
      for (RawRule raw : section.rules) {
        if (
          raw != null &&
          String.isNotBlank(raw.valueTypeName) &&
          !valueTypes.containsKey(raw.valueTypeName)
        ) {
          needed.add(raw.valueTypeName);
        }
      }
    }
    if (!needed.isEmpty()) {
      queryValueTypes(needed, valueTypes);
    }
  }

  private static void queryValueTypes(
    Set<String> needed,
    Map<String, IdpValueTypes.Config> valueTypes
  ) {
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
        Custom_Options__c,
        Value_Map_Entries__c
      FROM IDP_Value_Type__mdt
      WHERE DeveloperName IN :needed
    ]) {
      valueTypes.put(record.DeveloperName, toConfig(record));
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
    cfg.mapEntries = parseMapEntries(record.Value_Map_Entries__c);
    return cfg;
  }

  /**
   * Value_Map_Entries__c into MapEntry objects. A broken dictionary yields
   * no entries, which the ValueMap type then reports once per unmapped
   * value — louder than silently mapping nothing.
   */
  @TestVisible
  private static List<IdpValueTypes.MapEntry> parseMapEntries(
    String entriesJson
  ) {
    List<IdpValueTypes.MapEntry> entries = new List<IdpValueTypes.MapEntry>();
    if (String.isBlank(entriesJson)) {
      return entries;
    }
    RawValueMap parsed;
    try {
      parsed = (RawValueMap) JSON.deserialize(entriesJson, RawValueMap.class);
    } catch (Exception e) {
      return entries;
    }
    if (parsed == null || parsed.entries == null) {
      return entries;
    }
    for (RawMapEntry raw : parsed.entries) {
      if (raw == null || raw.active == false) {
        continue;
      }
      IdpValueTypes.MapEntry entry = new IdpValueTypes.MapEntry();
      entry.fromText = raw.fromText;
      entry.toValue = raw.toValue;
      if (String.isNotBlank(raw.matchStyle)) {
        entry.matchStyle = raw.matchStyle;
      }
      entries.add(entry);
    }
    return entries;
  }
}
