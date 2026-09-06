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
    /** Hub_Object__c: the object whose lookups are all followed when it is
     *  a root; null means the resolver's default (Document__c). */
    public String hubObject;
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
    /**
     * Explicit navigation. reachFrom names the anchor this section's
     * record is reached from — another Fixed section, or (when no section
     * has that name) the API name of an object the walk anchors on its
     * own: a root the file is linked to, or a hub parent. Null means the
     * implicit walk reaches the target by the unique lookup it finds.
     */
    public String reachFrom;
    /** True when reachFrom names a section rather than a root object. */
    public Boolean reachFromSection = false;
    /** Object of the record navigated from (set with reachFrom). */
    public String sourceObject;
    /** The lookup the hop follows, resolved at load time from `via` or —
     *  when via is absent — the one lookup Describe finds between the two
     *  objects. Set whenever reachFrom is. */
    public String relationshipField;
    /** True when the target holds the lookup back to the source (a child
     *  hop: newest child wins; the only shape rows can have); false when
     *  the source holds the lookup (a parent hop). */
    public Boolean childHop = false;
    /** reachFrom when it names a section — the older `parentSection` key
     *  read the same way; kept for callers that still ask by that name. */
    public String parentSectionName;
    /** rowScope: "None" — rows are matched by key alone, never scoped to
     *  a parent record. */
    public Boolean unscopedRows = false;
    /** True for a hop the loader synthesised from a multi-segment `via`
     *  (Case__c.AccountId): a rule-less Fixed section that only exists to
     *  anchor the intermediate record. */
    public Boolean synthetic = false;
    /** The synthesised hops of this section, source-first; moved into
     *  the set's section list once the path is validated. */
    public List<SectionConfig> hops = new List<SectionConfig>();
    /** "Create" opts a repeating section into creating unmatched rows. */
    public String unmatchedRowPolicy;
    /** "Create" opts a fixed section into creating its missing anchor. */
    public String noAnchorPolicy;
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
    /** ENG-9: relative weight of this field in the document confidence
     *  score; null/0 means "not interesting" — excluded from the roll-up. */
    public Decimal confidenceWeight;
    /** Mode = Custom: the resolved per-field handler (ENG-1). */
    public IIdpFieldHandler fieldHandler;
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
    public String hubObject;
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
    /** Older name for reachFrom; either key is accepted. */
    public String parentSection;
    public String reachFrom;
    public String via;
    public String hop;
    public String rowScope;
    public String unmatchedRows;
    public String whenNoAnchor;
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
    public String handlerClass;
    public String overwritePolicy;
    public String minGrade;
    public Decimal minConfidence;
    public Decimal confidenceWeight;
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
    SetConfig cached = cache.get(key); // assemble never returns null
    if (cached == null) {
      RawSet rawSet = querySet(mappingSetName);
      cached = assemble(
        rawSet,
        rawSet == null ? null : rawSet.definitionJson,
        new Map<String, IdpValueTypes.Config>()
      ); // filled inside assemble
      cache.put(key, cached);
    }
    return cached;
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
    config.hubObject = hubObjectFor(rawSet.hubObject, config);

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
    resolveNavigation(config, sectionsByName, kept);

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
    'reachFrom',
    'via',
    'hop',
    'rowScope',
    'unmatchedRows',
    'whenNoAnchor',
    'active',
    'rules'
  };

  public static final String HOP_PARENT = 'Parent';
  public static final String HOP_CHILD = 'Child';
  public static final String ROW_SCOPE_PARENT = 'Parent';
  public static final String ROW_SCOPE_NONE = 'None';

  private static final Set<String> RULE_KEYS = new Set<String>{
    'name',
    'label',
    'jsonPath',
    'targetField',
    'valueTypeName',
    'mode',
    'handlerClass',
    'overwritePolicy',
    'minGrade',
    'minConfidence',
    'confidenceWeight',
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
    if (
      String.isNotBlank(raw.reachFrom) &&
      String.isNotBlank(raw.parentSection) &&
      raw.reachFrom != raw.parentSection
    ) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Section ' +
          section.name +
          ' sets both reachFrom ("' +
          raw.reachFrom +
          '") and parentSection ("' +
          raw.parentSection +
          '"), which mean the same thing; reachFrom was used.'
      );
    }
    section.reachFrom = String.isNotBlank(raw.reachFrom)
      ? raw.reachFrom.trim()
      : String.isBlank(raw.parentSection) ? null : raw.parentSection.trim();
    section.unmatchedRowPolicy = creationPolicy(
      raw.unmatchedRows,
      'unmatchedRows',
      section.repeating,
      section.name,
      config
    );
    section.noAnchorPolicy = creationPolicy(
      raw.whenNoAnchor,
      'whenNoAnchor',
      !section.repeating,
      section.name,
      config
    );
    section.unscopedRows = rowScopePolicy(raw.rowScope, section, config);
    return section;
  }

  /** Validates unmatchedRows / whenNoAnchor: "Create" on the right section
   *  type, or nothing. Anything else is reported and dropped, never half-
   *  obeyed. */
  private static String creationPolicy(
    String value,
    String keyName,
    Boolean rightSectionType,
    String sectionName,
    SetConfig config
  ) {
    if (String.isBlank(value)) {
      return null;
    }
    if (value != 'Create') {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Section ' +
          sectionName +
          ' has unknown ' +
          keyName +
          ' value "' +
          value +
          '" — only "Create" is understood; the key was ignored.'
      );
      return null;
    }
    if (!rightSectionType) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Section ' +
          sectionName +
          ': ' +
          keyName +
          ' does not apply to this section type (unmatchedRows is for ' +
          'Repeating sections, whenNoAnchor for Fixed ones); it was ignored.'
      );
      return null;
    }
    return value;
  }

  // ───────────────────────── navigation ───────────────────────────

  /**
   * Settles every section's reachFrom / via / hop against the real schema
   * while both ends are known, so the run never has to guess: the source
   * is a surviving Fixed section or an object, and the lookup is the one
   * named by `via` — or the single one Describe finds. A Fixed section
   * whose path cannot be honoured is skipped rather than quietly reached
   * some other way; a Repeating section keeps the older behaviour of
   * dropping an unresolvable parent constraint with a warning, except
   * that an ambiguous one (several lookups, no via) also skips, because
   * scoping rows to the wrong parent is worse than not running them.
   * Sections reached from a skipped section, and reachFrom cycles, are
   * skipped in turn.
   */
  private static void resolveNavigation(
    SetConfig config,
    Map<String, SectionConfig> sectionsByName,
    List<RawSection> kept
  ) {
    Map<String, RawSection> rawByName = new Map<String, RawSection>();
    for (RawSection raw : kept) {
      rawByName.put(raw.name, raw);
    }
    Set<String> skipped = new Set<String>();
    for (SectionConfig section : config.sections) {
      if (section.reachFrom == null) {
        continue;
      }
      RawSection raw = rawByName.get(section.name);
      String failure = resolvePath(section, raw, sectionsByName, config);
      if (failure != null) {
        issue(
          config,
          IdpResult.SEV_WARNING,
          'Section ' +
            section.name +
            ' ' +
            failure +
            '; the section and its rules were skipped.'
        );
        skipped.add(section.name);
      }
    }
    // Hops synthesised from multi-segment paths join the set, each just
    // before the section that needed it, so the chain lists source-first.
    List<SectionConfig> withHops = new List<SectionConfig>();
    for (SectionConfig section : config.sections) {
      if (!skipped.contains(section.name)) {
        for (SectionConfig hopSection : section.hops) {
          sectionsByName.put(hopSection.name, hopSection);
          withHops.add(hopSection);
        }
      }
      withHops.add(section);
    }
    config.sections = withHops;
    // Cascade: a section reached from a skipped one, or inside a cycle,
    // cannot resolve either.
    Boolean changed = true;
    while (changed) {
      changed = false;
      for (SectionConfig section : config.sections) {
        if (skipped.contains(section.name) || !section.reachFromSection) {
          continue;
        }
        String problem;
        if (skipped.contains(section.reachFrom)) {
          problem =
            'reaches from section "' +
            section.reachFrom +
            '", which was skipped';
        } else {
          List<String> cycle = reachCycle(section, sectionsByName);
          if (cycle != null) {
            problem =
              'is in a reachFrom cycle (' +
              String.join(cycle, ' → ') +
              ')';
          }
        }
        if (problem != null) {
          issue(
            config,
            IdpResult.SEV_WARNING,
            'Section ' +
              section.name +
              ' ' +
              problem +
              '; the section and its rules were skipped.'
          );
          skipped.add(section.name);
          changed = true;
        }
      }
    }
    if (skipped.isEmpty()) {
      return;
    }
    List<SectionConfig> survivors = new List<SectionConfig>();
    for (SectionConfig section : config.sections) {
      if (!skipped.contains(section.name)) {
        survivors.add(section);
      } else {
        sectionsByName.remove(section.name);
      }
    }
    config.sections = survivors;
    for (Integer i = kept.size() - 1; i >= 0; i--) {
      if (skipped.contains(kept[i].name)) {
        kept.remove(i);
      }
    }
  }

  /** Resolves one section's source and lookup. Returns null when the path
   *  is usable (the section's navigation fields are filled in) or when a
   *  Repeating section's constraint was dropped with a warning; otherwise
   *  the reason the section must be skipped. */
  private static String resolvePath(
    SectionConfig section,
    RawSection raw,
    Map<String, SectionConfig> sectionsByName,
    SetConfig config
  ) {
    String target = section.targetObject;
    SectionConfig source = sectionsByName.get(section.reachFrom);
    if (source == section) {
      return 'reaches from itself';
    }
    if (source != null) {
      if (source.repeating) {
        return 'reaches from Repeating section "' +
          source.name +
          '"; only a Fixed section (one record) or a root object can be reached from';
      }
      section.reachFromSection = true;
      section.sourceObject = source.targetObject;
      section.parentSectionName = source.name;
    } else if (IdpSchemaCache.typeOf(section.reachFrom) != null) {
      section.reachFromSection = false;
      section.sourceObject = IdpSchemaCache.describe(section.reachFrom)
        .getName();
    } else if (section.repeating) {
      // Older behaviour, kept: an unknown parent drops the constraint.
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Section ' +
          section.name +
          ' names unknown or inactive parent section "' +
          section.reachFrom +
          '"; the parent constraint was dropped.'
      );
      section.reachFrom = null;
      return null;
    } else {
      return 'reaches from "' +
        section.reachFrom +
        '", which is neither a section nor an object';
    }
    String sourceObject = section.sourceObject;

    String hop = raw == null || String.isBlank(raw.hop) ? null : raw.hop.trim();
    if (
      hop != null &&
      !hop.equalsIgnoreCase(HOP_PARENT) &&
      !hop.equalsIgnoreCase(HOP_CHILD)
    ) {
      return 'has unknown hop value "' +
        hop +
        '" — only "' +
        HOP_PARENT +
        '" or "' +
        HOP_CHILD +
        '" is understood';
    }
    if (hop != null && hop.equalsIgnoreCase(HOP_PARENT) && section.repeating) {
      return 'has hop "Parent", but rows always hold the lookup to their parent (a Child hop)';
    }
    Boolean wantParent = hop != null && hop.equalsIgnoreCase(HOP_PARENT);
    Boolean wantChild = hop != null && hop.equalsIgnoreCase(HOP_CHILD);

    String via = raw == null || String.isBlank(raw.via) ? null : raw.via.trim();
    if (via != null && via.contains('.')) {
      List<String> segments = via.split('\\.');
      Schema.DescribeFieldResult first = IdpSchemaCache.fieldDescribe(
        sourceObject,
        segments[0]
      );
      // A multi-segment path (Case__c.AccountId) starts with a lookup on
      // the source; Object.Field starts with an object name and is
      // handled below as a qualifier.
      if (first != null && first.getType() == Schema.DisplayType.REFERENCE) {
        String failure = expandPath(section, via, segments);
        if (failure != null) {
          return failure;
        }
        sourceObject = section.sourceObject;
        via = segments[segments.size() - 1];
      }
    }
    if (via == null) {
      return discoverPath(
        section,
        sourceObject,
        target,
        wantParent,
        wantChild,
        config
      );
    }

    // `via` may be qualified, Object.Field, like targetField; the object
    // half then says which side holds the lookup.
    String viaObject = via.contains('.') ? via.substringBeforeLast('.') : null;
    String viaField = bareField(via);
    if (viaObject != null) {
      if (
        viaObject.equalsIgnoreCase(sourceObject) &&
        !sourceObject.equalsIgnoreCase(target)
      ) {
        wantParent = true;
      } else if (
        viaObject.equalsIgnoreCase(target) &&
        !sourceObject.equalsIgnoreCase(target)
      ) {
        wantChild = true;
      } else if (
        !viaObject.equalsIgnoreCase(sourceObject) &&
        !viaObject.equalsIgnoreCase(target)
      ) {
        return 'names via "' +
          via +
          '", but ' +
          viaObject +
          ' is neither the source (' +
          sourceObject +
          ') nor the target (' +
          target +
          '), and ' +
          sourceObject +
          '.' +
          viaObject +
          ' is not a lookup to start a path from';
      }
    }
    Boolean onSource =
      !section.repeating &&
      IdpSchemaCache.references(sourceObject, viaField, target);
    Boolean onTarget = IdpSchemaCache.references(
      target,
      viaField,
      sourceObject
    );
    if (wantParent && !onSource) {
      return 'has hop "Parent" but ' +
        sourceObject +
        '.' +
        viaField +
        ' is not a lookup to ' +
        target;
    }
    if (wantChild && !onTarget) {
      return 'has hop "Child" but ' +
        target +
        '.' +
        viaField +
        ' is not a lookup to ' +
        sourceObject;
    }
    if (onSource && onTarget && !wantParent && !wantChild) {
      return 'names via "' +
        viaField +
        '", which could be followed either way between ' +
        sourceObject +
        ' and ' +
        target +
        '; set hop to "' +
        HOP_PARENT +
        '" or "' +
        HOP_CHILD +
        '"';
    }
    if (!onSource && !onTarget) {
      return 'names via "' +
        viaField +
        '", but ' +
        sourceObject +
        '.' +
        viaField +
        ' is not a lookup to ' +
        target +
        (section.repeating
          ? ''
          : ', nor ' +
            target +
            '.' +
            viaField +
            ' a lookup to ' +
            sourceObject);
    }
    section.childHop = wantChild || (onTarget && !onSource);
    section.relationshipField = canonicalFieldName(
      section.childHop ? target : sourceObject,
      viaField
    );
    return null;
  }

  /** No `via`: the one lookup Describe finds decides; several is an
   *  ambiguity the admin settles with via, never a guess. */
  private static String discoverPath(
    SectionConfig section,
    String sourceObject,
    String target,
    Boolean wantParent,
    Boolean wantChild,
    SetConfig config
  ) {
    if (sourceObject.equalsIgnoreCase(target)) {
      return 'reaches ' +
        target +
        ' from ' +
        sourceObject +
        ' — a self-relationship needs via (the lookup field) and hop';
    }
    List<String> parents = section.repeating || wantChild
      ? new List<String>()
      : IdpSchemaCache.lookupsTo(sourceObject, target);
    List<String> children = wantParent
      ? new List<String>()
      : IdpSchemaCache.lookupsTo(target, sourceObject);
    if (parents.size() + children.size() == 1) {
      section.childHop = children.size() == 1;
      section.relationshipField = section.childHop ? children[0] : parents[0];
      return null;
    }
    if (parents.isEmpty() && children.isEmpty()) {
      if (section.repeating) {
        // Older behaviour, kept: rows run unscoped when nothing joins them.
        issue(
          config,
          IdpResult.SEV_WARNING,
          'Section ' +
            section.name +
            ': no lookup joins ' +
            target +
            ' to ' +
            sourceObject +
            ', so the parent constraint was dropped and its rows are not ' +
            'scoped to a parent record.'
        );
        section.reachFrom = null;
        section.reachFromSection = false;
        section.sourceObject = null;
        section.parentSectionName = null;
        return null;
      }
      return 'has no lookup between ' + sourceObject + ' and ' + target;
    }
    List<String> candidates = new List<String>();
    for (String field : parents) {
      candidates.add(sourceObject + '.' + field);
    }
    for (String field : children) {
      candidates.add(target + '.' + field);
    }
    return 'is reachable from ' +
      sourceObject +
      ' through several lookups (' +
      String.join(candidates, ', ') +
      '); set via to choose one';
  }

  private static String canonicalFieldName(
    String objectName,
    String fieldName
  ) {
    Schema.DescribeFieldResult described = IdpSchemaCache.fieldDescribe(
      objectName,
      fieldName
    );
    return described == null ? fieldName : described.getName();
  }

  /**
   * Turns every segment of a path but the last into a synthesised Fixed
   * section — a parent hop through the named lookup — chained from the
   * section's source, and moves the section's own source to the end of
   * that chain. The last segment is then resolved like a plain `via`.
   * Intermediate lookups must point at exactly one object: a polymorphic
   * one (OwnerId) would leave the next hop's object unknown.
   */
  private static String expandPath(
    SectionConfig section,
    String via,
    List<String> segments
  ) {
    String current = section.sourceObject;
    String previousKey = section.reachFrom;
    Boolean previousIsSection = section.reachFromSection;
    for (Integer i = 0; i < segments.size() - 1; i++) {
      String segment = segments[i];
      Schema.DescribeFieldResult described = IdpSchemaCache.fieldDescribe(
        current,
        segment
      );
      if (
        described == null ||
        described.getType() != Schema.DisplayType.REFERENCE
      ) {
        return 'names via "' +
          via +
          '", but ' +
          current +
          '.' +
          segment +
          ' is not a lookup';
      }
      if (described.getReferenceTo().size() != 1) {
        return 'names via "' +
          via +
          '", but ' +
          current +
          '.' +
          segment +
          ' can point at several objects; an intermediate hop must point at one';
      }
      String next = described.getReferenceTo()[0].getDescribe().getName();
      SectionConfig hopSection = new SectionConfig();
      hopSection.name = section.name + ' › ' + described.getName();
      hopSection.label = hopSection.name;
      hopSection.targetObject = next;
      hopSection.reachFrom = previousKey;
      hopSection.reachFromSection = previousIsSection;
      hopSection.sourceObject = current;
      hopSection.relationshipField = described.getName();
      hopSection.childHop = false;
      hopSection.synthetic = true;
      section.hops.add(hopSection);
      previousKey = hopSection.name;
      previousIsSection = true;
      current = next;
    }
    section.reachFrom = previousKey;
    section.reachFromSection = true;
    section.sourceObject = current;
    return null;
  }

  /** Hub_Object__c, checked against the schema; blank or unknown falls
   *  back to the resolver's default hub. */
  private static String hubObjectFor(String hubObject, SetConfig config) {
    if (String.isBlank(hubObject)) {
      return null;
    }
    Schema.DescribeSObjectResult described = IdpSchemaCache.describe(
      hubObject.trim()
    );
    if (described == null) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Mapping set ' +
          config.name +
          ' names unknown Hub Object "' +
          hubObject +
          '"; the default hub (Document__c) was used.'
      );
      return null;
    }
    return described.getName();
  }

  /** rowScope: "Parent" (default) scopes rows to a parent record; "None"
   *  matches rows by key alone and makes reachFrom / via meaningless on
   *  that section. Repeating sections only. */
  private static Boolean rowScopePolicy(
    String value,
    SectionConfig section,
    SetConfig config
  ) {
    if (String.isBlank(value)) {
      return false;
    }
    String trimmed = value.trim();
    if (
      !trimmed.equalsIgnoreCase(ROW_SCOPE_PARENT) &&
      !trimmed.equalsIgnoreCase(ROW_SCOPE_NONE)
    ) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Section ' +
          section.name +
          ' has unknown rowScope value "' +
          value +
          '" — only "Parent" or "None" is understood; the key was ignored.'
      );
      return false;
    }
    if (!section.repeating) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Section ' +
          section.name +
          ': rowScope applies to Repeating sections only; it was ignored.'
      );
      return false;
    }
    if (!trimmed.equalsIgnoreCase(ROW_SCOPE_NONE)) {
      return false;
    }
    if (section.reachFrom != null) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Section ' +
          section.name +
          ' has rowScope "None", so its reachFrom / via were ignored: rows ' +
          'are matched by key alone.'
      );
      section.reachFrom = null;
    }
    return true;
  }

  /** The chain of reachFrom section names starting at this section when
   *  it loops back; null otherwise. */
  private static List<String> reachCycle(
    SectionConfig start,
    Map<String, SectionConfig> sectionsByName
  ) {
    List<String> chain = new List<String>{ start.name };
    SectionConfig current = start;
    for (Integer i = 0; i <= sectionsByName.size(); i++) {
      if (!current.reachFromSection) {
        return null;
      }
      SectionConfig next = sectionsByName.get(current.reachFrom);
      if (next == null) {
        return null;
      }
      chain.add(next.name);
      if (next == start) {
        return chain;
      }
      current = next;
    }
    return null;
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
      raw.mode != IdpMappingEngine.MODE_COMPLIANCE &&
      raw.mode != IdpMappingEngine.MODE_CUSTOM
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
    if (raw.confidenceWeight != null && raw.confidenceWeight < 0) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Rule ' + ruleName + ' has a negative confidenceWeight; it was ignored.'
      );
    } else {
      rule.confidenceWeight = raw.confidenceWeight;
    }

    if (rule.mode == IdpMappingEngine.MODE_CUSTOM) {
      rule.fieldHandler = resolveFieldHandler(
        raw.handlerClass,
        ruleName,
        config
      );
      if (rule.fieldHandler == null) {
        return; // the issue is already recorded
      }
    } else if (String.isNotBlank(raw.handlerClass)) {
      issue(
        config,
        IdpResult.SEV_WARNING,
        'Rule ' +
          ruleName +
          ' names a handlerClass but its Mode is not Custom; the handler ' +
          'was ignored.'
      );
    }

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
   * Resolves a Mode = Custom rule's handler at load time — same DI
   * convention as finding handlers — so a typo is a config finding here,
   * not a runtime surprise. Null (with the issue recorded) when it cannot
   * be used.
   */
  private static IIdpFieldHandler resolveFieldHandler(
    String className,
    String ruleName,
    SetConfig config
  ) {
    String failure;
    if (String.isBlank(className)) {
      failure = 'has Mode "Custom" but no handlerClass';
    } else {
      Type handlerType = Type.forName(className);
      if (handlerType == null) {
        failure = 'names unknown handler class "' + className + '"';
      } else {
        Object instance;
        try {
          instance = handlerType.newInstance();
        } catch (Exception e) {
          failure =
            'has a handler class "' +
            className +
            '" that could not be instantiated: ' +
            e.getMessage();
        }
        if (failure == null && !(instance instanceof IIdpFieldHandler)) {
          failure =
            'has a handler class "' +
            className +
            '" that does not implement IIdpFieldHandler';
        }
        if (failure == null) {
          return (IIdpFieldHandler) instance;
        }
      }
    }
    issue(
      config,
      IdpResult.SEV_WARNING,
      'Rule ' + ruleName + ' ' + failure + '; the rule was skipped.'
    );
    return null;
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
        Hub_Object__c,
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
    raw.hubObject = records[0].Hub_Object__c;
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
