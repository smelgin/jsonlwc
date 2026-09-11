/**
 * Unit tests for IdpConfigLoader.
 *
 * Validates config assembly and validation at two levels: the Raw* DTO
 * level, where misconfiguration must degrade to issues while the rest of
 * the set still runs, and the JSON level, where a hand-edited Definition
 * must parse — or fail loudly enough that an admin can fix it.
 *
 * Custom metadata cannot be inserted in tests, so the set record itself is
 * hand-built; the query to raw mapping is mechanical.
 */
@IsTest
private class IdpConfigLoaderTest {
  /**
   * Builds the mapping set record the tests assemble against.
   *
   * @return The raw set.
   */
  private static IdpConfigLoader.RawSet rawSet() {
    IdpConfigLoader.RawSet raw = new IdpConfigLoader.RawSet();
    raw.name = 'Test_Set';
    raw.label = 'Test Set';
    raw.defaultMode = 'Extraction';
    return raw;
  }

  /**
   * Builds a section of the given type.
   *
   * @param name Section name.
   * @param sectionType "Fixed" or "Repeating".
   * @param targetObject API name of the object it writes to.
   * @return The raw section.
   */
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

  /**
   * Builds an extraction rule.
   *
   * @param name Rule name.
   * @param jsonPath Path the value is read from.
   * @param targetField API name of the field it writes to.
   * @return The raw rule.
   */
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
  /**
   * Assembles a config through the loader, without touching the cache.
   *
   * @param mappingSet The mapping set record.
   * @param sections Sections making up the definition.
   * @param valueTypes Value types supplied instead of being queried.
   * @return The assembled configuration, issues included.
   */
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

  /**
   * Verifies that a name no active mapping set answers to yields an error
   * issue rather than an exception.
   */
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

  /**
   * Verifies that a well-formed set assembles with its sections and rules
   * intact and no issues.
   */
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

  /**
   * Verifies that a section naming an object the schema lacks is skipped
   * while the rest of the set survives.
   */
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

  /**
   * Verifies that a rule naming a field the object lacks is skipped while
   * its section survives.
   */
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

  /**
   * Verifies that a field written as Object.Field is accepted and reduced to
   * its bare name.
   */
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

  /**
   * Verifies that a Repeating section missing what it needs takes its rules
   * with it.
   */
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

  /**
   * Verifies that rows cannot be matched on a field the object lacks.
   */
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

  /**
   * Verifies that deactivated sections and rules are left out without being
   * reported as problems.
   */
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

  /**
   * Verifies that a parent section no other section defines is dropped with
   * a warning.
   */
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

  /**
   * Builds a Fixed section reached through a declared path.
   *
   * @param name Section name.
   * @param targetObject API name of the object it writes to.
   * @param reachFrom Anchor the section is reached from.
   * @param via Lookup the hop follows.
   * @return The raw section, carrying one rule.
   */
  private static IdpConfigLoader.RawSection reaching(
    String name,
    String targetObject,
    String reachFrom,
    String via
  ) {
    IdpConfigLoader.RawSection raw = rawSection(name, 'Fixed', targetObject);
    raw.reachFrom = reachFrom;
    raw.via = via;
    raw.rules.add(rawRule(name + '_R', 'a', 'Name'));
    return raw;
  }

  /**
   * Builds a Repeating section reached through a declared path.
   *
   * @param name Section name.
   * @param targetObject API name of the row object.
   * @param reachFrom Anchor the rows are scoped to.
   * @param via Lookup the hop follows.
   * @return The raw section.
   */
  private static IdpConfigLoader.RawSection rows(
    String name,
    String targetObject,
    String reachFrom,
    String via
  ) {
    IdpConfigLoader.RawSection raw = rawSection(
      name,
      'Repeating',
      targetObject
    );
    raw.rowPath = 'Details';
    raw.matchField = targetObject == 'Case' ? 'Subject' : 'Name';
    raw.matchValue = '{row:number}';
    raw.reachFrom = reachFrom;
    raw.via = via;
    return raw;
  }

  /**
   * Assembles the sections against the default set record.
   *
   * @param sections Sections making up the definition.
   * @return The assembled configuration, issues included.
   */
  private static IdpConfigLoader.SetConfig assembleAll(
    List<IdpConfigLoader.RawSection> sections
  ) {
    return assemble(
      rawSet(),
      sections,
      new Map<String, IdpValueTypes.Config>()
    );
  }

  /**
   * Renders a config's issues as text, for substring assertions.
   *
   * @param config Configuration to inspect.
   * @return Its issues serialized to JSON.
   */
  private static String issues(IdpConfigLoader.SetConfig config) {
    return JSON.serialize(config.issues);
  }

  /**
   * Verifies that a named lookup settles the hop direction from the schema
   * without the admin stating it.
   */
  @IsTest
  static void viaResolvesDirectionFromDescribe() {
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        reaching('Holder', 'Account', 'Case', 'AccountId'),
        reaching('Holding', 'Asset', 'Holder', 'AssetServicedById')
      }
    );
    Assert.areEqual(0, config.issues.size(), issues(config));
    IdpConfigLoader.SectionConfig holder = config.sections[0];
    Assert.isFalse(holder.reachFromSection, 'Case is a root object here');
    Assert.areEqual('Case', holder.sourceObject);
    Assert.areEqual('AccountId', holder.relationshipField);
    Assert.isFalse(holder.childHop, 'Case holds the lookup: a parent hop');
    Assert.isNull(holder.parentSectionName);

    IdpConfigLoader.SectionConfig holding = config.sections[1];
    Assert.isTrue(holding.reachFromSection);
    Assert.areEqual('Holder', holding.parentSectionName);
    Assert.areEqual('Account', holding.sourceObject);
    Assert.areEqual('AssetServicedById', holding.relationshipField);
    Assert.isTrue(holding.childHop, 'Asset holds the lookup: a child hop');
  }

  /**
   * Verifies that a qualified or mis-cased via is accepted and restored to
   * the schema spelling.
   */
  @IsTest
  static void viaAcceptsQualifiedNamesAndCanonicalisesCase() {
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        reaching('Holder', 'Account', 'Case', 'case.accountid'),
        reaching('Wrong', 'Account', 'Case', 'Contact.AccountId')
      }
    );
    Assert.areEqual(1, config.sections.size(), issues(config));
    Assert.areEqual('AccountId', config.sections[0].relationshipField);
    Assert.isTrue(
      issues(config).contains('neither the source'),
      issues(config)
    );
  }

  /**
   * Verifies that a single lookup between two objects is found without via.
   */
  @IsTest
  static void withoutViaTheOnlyLookupIsDiscovered() {
    // Case.ContactId is the one lookup between Case and Contact.
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        reaching('Signatory', 'Contact', 'Case', null)
      }
    );
    Assert.areEqual(0, config.issues.size(), issues(config));
    Assert.areEqual('ContactId', config.sections[0].relationshipField);
    Assert.isFalse(config.sections[0].childHop);
  }

  /**
   * Verifies that competing lookups skip the section and the issue lists the
   * candidates, so nothing is guessed.
   */
  @IsTest
  static void severalLookupsWithoutViaSkipTheSectionNamingThem() {
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        rawSection('Customer', 'Fixed', 'Account'),
        reaching('Holding', 'Asset', 'Customer', null)
      }
    );
    Assert.areEqual(1, config.sections.size(), issues(config));
    Assert.areEqual('Customer', config.sections[0].name);
    String text = issues(config);
    Assert.isTrue(text.contains('Asset.AccountId'), text);
    Assert.isTrue(text.contains('Asset.AssetServicedById'), text);
    Assert.isTrue(text.contains('set via'), text);
  }

  /**
   * Verifies that a named lookup joining neither object skips the section.
   */
  @IsTest
  static void viaThatJoinsNothingSkipsTheSection() {
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        reaching('Holder', 'Account', 'Case', 'ParentId')
      }
    );
    Assert.areEqual(0, config.sections.size(), issues(config));
    Assert.isTrue(
      issues(config).contains('is not a lookup to'),
      issues(config)
    );
  }

  /**
   * Verifies that a lookup from an object to itself is only usable when the
   * direction is stated.
   */
  @IsTest
  static void selfRelationshipsNeedHop() {
    IdpConfigLoader.RawSection noHop = reaching(
      'Parent_Account',
      'Account',
      'Account',
      'ParentId'
    );
    IdpConfigLoader.RawSection up = reaching(
      'Up',
      'Account',
      'Account',
      'ParentId'
    );
    up.hop = 'Parent';
    IdpConfigLoader.RawSection down = reaching(
      'Down',
      'Account',
      'Account',
      'ParentId'
    );
    down.hop = 'Child';
    IdpConfigLoader.RawSection sideways = reaching(
      'Sideways',
      'Account',
      'Account',
      'ParentId'
    );
    sideways.hop = 'Across';
    IdpConfigLoader.RawSection undiscoverable = reaching(
      'Undiscoverable',
      'Account',
      'Account',
      null
    );

    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        noHop,
        up,
        down,
        sideways,
        undiscoverable
      }
    );
    Assert.areEqual(2, config.sections.size(), issues(config));
    Assert.areEqual('Up', config.sections[0].name);
    Assert.isFalse(config.sections[0].childHop);
    Assert.areEqual('Down', config.sections[1].name);
    Assert.isTrue(config.sections[1].childHop);
    String text = issues(config);
    Assert.isTrue(text.contains('either way'), text);
    Assert.isTrue(text.contains('unknown hop value'), text);
    Assert.isTrue(text.contains('self-relationship'), text);
  }

  /**
   * Verifies that a stated direction the schema cannot support is refused.
   */
  @IsTest
  static void hopThatContradictsTheSchemaIsRejected() {
    IdpConfigLoader.RawSection wrong = reaching(
      'Holder',
      'Account',
      'Case',
      'AccountId'
    );
    wrong.hop = 'Child';
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{ wrong }
    );
    Assert.areEqual(0, config.sections.size(), issues(config));
    Assert.isTrue(issues(config).contains('has hop'), issues(config));
  }

  /**
   * Verifies that a path may start only at a Fixed section or at an object
   * the walk anchors on its own.
   */
  @IsTest
  static void reachFromMustNameAFixedSectionOrAnObject() {
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        rows('Lines', 'Asset', null, null),
        reaching('From_Rows', 'Account', 'Lines', 'AccountId'),
        reaching('From_Nowhere', 'Account', 'Nowhere', 'AccountId'),
        reaching('From_Self', 'Account', 'From_Self', 'ParentId')
      }
    );
    Assert.areEqual(1, config.sections.size(), issues(config));
    Assert.areEqual('Lines', config.sections[0].name);
    String text = issues(config);
    Assert.isTrue(text.contains('Repeating section'), text);
    Assert.isTrue(text.contains('neither a section nor an object'), text);
    Assert.isTrue(text.contains('from itself'), text);
  }

  /**
   * Verifies that a section reached from a skipped one is skipped in turn.
   */
  @IsTest
  static void dependentsOfSkippedSectionsAreSkipped() {
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        reaching('Broken', 'Account', 'Case', 'NoSuchField__c'),
        reaching('Dependent', 'Contact', 'Broken', 'AccountId')
      }
    );
    Assert.areEqual(0, config.sections.size(), issues(config));
    Assert.isTrue(issues(config).contains('which was skipped'), issues(config));
  }

  /**
   * Verifies that sections reaching each other in a loop are all skipped,
   * though each path is valid alone.
   */
  @IsTest
  static void cycleIsDetectedWhenEachPathIsValidOnItsOwn() {
    IdpConfigLoader.RawSection a = reaching('A', 'Account', 'B', 'ParentId');
    a.hop = 'Parent';
    IdpConfigLoader.RawSection b = reaching('B', 'Account', 'A', 'ParentId');
    b.hop = 'Parent';
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{ a, b }
    );
    Assert.areEqual(0, config.sections.size(), issues(config));
    Assert.isTrue(issues(config).contains('reachFrom cycle'), issues(config));
  }

  /**
   * Verifies that the older parentSection key is read exactly as reachFrom.
   */
  @IsTest
  static void parentSectionIsAnAliasOfReachFrom() {
    IdpConfigLoader.RawSection lines = rows(
      'Lines',
      'Asset',
      null,
      'AccountId'
    );
    lines.parentSection = 'Customer';
    IdpConfigLoader.RawSection both = rows(
      'Both',
      'Asset',
      'Customer',
      'AccountId'
    );
    both.parentSection = 'Nowhere';
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        rawSection('Customer', 'Fixed', 'Account'),
        lines,
        both
      }
    );
    Assert.areEqual(3, config.sections.size(), issues(config));
    Assert.areEqual('Customer', config.sections[1].parentSectionName);
    Assert.areEqual('Customer', config.sections[1].reachFrom);
    Assert.areEqual('AccountId', config.sections[1].relationshipField);
    Assert.isTrue(config.sections[1].childHop);
    Assert.areEqual('Customer', config.sections[2].reachFrom, 'reachFrom wins');
    Assert.areEqual(1, config.issues.size(), issues(config));
    Assert.isTrue(issues(config).contains('mean the same thing'));
  }

  /**
   * Verifies that rows whose parent lookup is ambiguous are skipped, since
   * scoping to the wrong parent is worse than not running.
   */
  @IsTest
  static void repeatingSectionWithAmbiguousParentIsSkipped() {
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        rawSection('Customer', 'Fixed', 'Account'),
        rows('Lines', 'Asset', 'Customer', null)
      }
    );
    Assert.areEqual(1, config.sections.size(), issues(config));
    Assert.isTrue(issues(config).contains('several lookups'), issues(config));
  }

  /**
   * Verifies that a repeating section's via must name a lookup the row
   * object itself holds.
   */
  @IsTest
  static void repeatingSectionViaMustBeOnTheRowObject() {
    // Contact.ReportsToId is a lookup on the source, not on the rows —
    // rows always hold the lookup to their parent.
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        rows('Cases', 'Case', 'Contact', 'ReportsToId'),
        rows('Cases2', 'Case', 'Contact', 'ContactId')
      }
    );
    Assert.areEqual(1, config.sections.size(), issues(config));
    Assert.areEqual('Cases2', config.sections[0].name);
    Assert.areEqual('ContactId', config.sections[0].relationshipField);
  }

  /**
   * Verifies that rows with nothing joining them to their parent run
   * unscoped, with a warning.
   */
  @IsTest
  static void repeatingSectionWithNoJoinDropsTheConstraintWithAWarning() {
    // Nothing joins Case and Opportunity.
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        rows('Cases', 'Case', 'Opportunity', null)
      }
    );
    Assert.areEqual(1, config.sections.size(), issues(config));
    Assert.isNull(config.sections[0].reachFrom);
    Assert.isNull(config.sections[0].relationshipField);
    Assert.isTrue(issues(config).contains('dropped'), issues(config));
  }

  /**
   * Verifies that every navigation key survives the unknown-key screen.
   */
  @IsTest
  static void navigationKeysAreKnownToTheKeyScreen() {
    IdpConfigLoader.SetConfig config = IdpConfigLoader.assemble(
      rawSet(),
      '{"sections":[{"name":"Holder","targetObject":"Account",' +
      '"reachFrom":"Case","via":"AccountId","hop":"Parent","rules":[]}]}',
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual(0, config.issues.size(), issues(config));
    Assert.areEqual('AccountId', config.sections[0].relationshipField);
  }

  /**
   * Verifies that a multi-segment via becomes a chain of synthesised
   * rule-less sections.
   */
  @IsTest
  static void multiSegmentViaExpandsIntoHiddenHops() {
    // Case.ContactId → Contact, then Contact.AccountId → Account.
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        reaching('Holder', 'Account', 'Case', 'ContactId.AccountId')
      }
    );
    Assert.areEqual(0, config.issues.size(), issues(config));
    Assert.areEqual(2, config.sections.size());
    IdpConfigLoader.SectionConfig hopSection = config.sections[0];
    Assert.isTrue(hopSection.synthetic);
    Assert.areEqual('Holder › ContactId', hopSection.name);
    Assert.areEqual('Contact', hopSection.targetObject);
    Assert.areEqual('Case', hopSection.sourceObject);
    Assert.areEqual('ContactId', hopSection.relationshipField);
    Assert.isFalse(hopSection.reachFromSection, 'starts at the Case root');
    Assert.isTrue(hopSection.rules.isEmpty());
    IdpConfigLoader.SectionConfig holder = config.sections[1];
    Assert.areEqual('Holder › ContactId', holder.reachFrom);
    Assert.isTrue(holder.reachFromSection);
    Assert.areEqual('Contact', holder.sourceObject);
    Assert.areEqual('AccountId', holder.relationshipField);
    Assert.isFalse(holder.childHop);
  }

  /**
   * Verifies that an intermediate segment that is not a single-target lookup
   * skips the section.
   */
  @IsTest
  static void multiSegmentViaRejectsBadIntermediates() {
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        reaching('Poly', 'Account', 'Case', 'OwnerId.AccountId'),
        reaching('Typo', 'Account', 'Case', 'Nope__c.AccountId')
      }
    );
    Assert.areEqual(0, config.sections.size(), issues(config));
    String text = issues(config);
    Assert.isTrue(text.contains('several objects'), text);
    Assert.isTrue(
      text.contains('Case.Nope__c is not a lookup to start a path from'),
      text
    );
  }

  /**
   * Verifies that rowScope "None" unscopes repeating rows and is ignored,
   * with a warning, on a Fixed section.
   */
  @IsTest
  static void rowScopeNoneDropsParentScopingOnRepeatingSectionsOnly() {
    IdpConfigLoader.RawSection unscoped = rows(
      'Lines',
      'Asset',
      'Customer',
      'AccountId'
    );
    unscoped.rowScope = 'None';
    IdpConfigLoader.RawSection fixedScope = reaching(
      'Holder',
      'Account',
      'Case',
      'AccountId'
    );
    fixedScope.rowScope = 'None';
    IdpConfigLoader.RawSection bad = rows('Bad', 'Asset', null, null);
    bad.rowScope = 'Everything';
    IdpConfigLoader.SetConfig config = assembleAll(
      new List<IdpConfigLoader.RawSection>{
        rawSection('Customer', 'Fixed', 'Account'),
        unscoped,
        fixedScope,
        bad
      }
    );
    Assert.areEqual(4, config.sections.size(), issues(config));
    Assert.isTrue(config.sections[1].unscopedRows);
    Assert.isNull(config.sections[1].reachFrom, 'reachFrom is meaningless');
    Assert.isFalse(config.sections[2].unscopedRows);
    Assert.isFalse(config.sections[3].unscopedRows);
    String text = issues(config);
    Assert.isTrue(text.contains('reachFrom / via were ignored'), text);
    Assert.isTrue(text.contains('Repeating sections only'), text);
    Assert.isTrue(text.contains('unknown rowScope value'), text);
  }

  /**
   * Verifies that an unknown Hub Object falls back to the default hub with a
   * warning.
   */
  @IsTest
  static void hubObjectIsCheckedAgainstTheSchema() {
    IdpConfigLoader.RawSet withHub = rawSet();
    withHub.hubObject = 'case';
    IdpConfigLoader.SetConfig config = assemble(
      withHub,
      new List<IdpConfigLoader.RawSection>(),
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.areEqual('Case', config.hubObject, 'canonical API name');

    IdpConfigLoader.RawSet badHub = rawSet();
    badHub.hubObject = 'Nope__c';
    config = assemble(
      badHub,
      new List<IdpConfigLoader.RawSection>(),
      new Map<String, IdpValueTypes.Config>()
    );
    Assert.isNull(config.hubObject, 'falls back to the default hub');
    Assert.isTrue(issues(config).contains('Hub Object'), issues(config));
  }

  /**
   * Verifies that a rule naming a value type the org lacks is skipped.
   */
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

  /**
   * Verifies that a Custom rule whose class cannot be resolved is skipped at
   * load time.
   */
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

  /**
   * Verifies that unusable regex patterns, currencies, regions and timezones
   * are reported before any document runs.
   */
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

  /**
   * Verifies that a locale with no country or language record is reported
   * rather than silently degraded.
   */
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

  /**
   * Verifies that a Date type reading month names in a language declaring
   * none is warned about.
   */
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

  /**
   * Verifies that grades, modes and overwrite policies are read onto the
   * rule, with unknown values reported.
   */
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

  /**
   * Verifies that a definition written by hand assembles the same as one
   * built from DTOs.
   */
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

  /**
   * Verifies that malformed definition JSON disables the whole set with an
   * error issue rather than throwing.
   */
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

  /**
   * Verifies that a misspelled rule key stops the load, since ignoring it
   * would map nothing without saying so.
   */
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

  /**
   * Verifies that the unknown-key screen covers section keys too.
   */
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

  /**
   * Verifies that a set with no definition warns that it maps nothing.
   */
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

  /**
   * Verifies that every IDP_Value_Type__mdt field reaches the configuration
   * it drives.
   */
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

  /**
   * Verifies that value map JSON becomes translations, inactive entries
   * left out.
   */
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

  /**
   * Verifies that an unusable value map compiles to nothing, so the type
   * reports each unmapped value.
   */
  @IsTest
  static void brokenValueMapYieldsNoEntries() {
    Assert.areEqual(
      0,
      IdpConfigLoader.parseMapEntries('{"entries":[').size(),
      'a broken dictionary maps nothing rather than mapping wrongly'
    );
    Assert.areEqual(0, IdpConfigLoader.parseMapEntries(null).size());
  }

  /** Stands in for a real custom handler — validateDefinition only checks
   *  that a handlerClass resolves and instantiates, it never calls handle(). */
  public class ContractHandler implements IIdpFieldHandler {
    /**
     * Does nothing; only its resolvability is under test.
     *
     * @param context Field origin, parse outcome and the record.
     */
    public void handle(IdpFieldContext context) {
    }
  }

  /**
   * ADR-0001 (force-app/idp/main/config/docs) commits the builder to two
   * rules stricter than the engine requires: every hop is its own node —
   * no multi-segment via — and every creation policy is written, never
   * inferred. This is the reference definition that shape produces,
   * hand-written the way an admin's clicks would assemble it, covering
   * every gesture the canvas and panel expose. It is the builder's
   * contract with the engine: if this ever stops loading clean, the
   * builder's write path and this test must change together.
   *
   *   Header (Case, the hub)
   *     ├─rule: valueTypeName omitted on purpose — SuppliedEmail is an
   *     │  Email field, so the derived type is already strict; no base
   *     │  value type ships with the engine itself to name here.
   *     └─via Case.AccountId──> Applicant (Account)            whenNoAnchor: Create
   *          ├─via Account.OwnerId──> OwnerLink (User)          pass-through, no rules
   *          │    └─via User.ProfileId──> OwnerProfile (Profile)
   *          └─via Asset.AccountId, hop Child──> Lines (Asset, Repeating)  unmatchedRows: Create
   *   Warranties (Asset, Repeating, rowScope None — matched by key alone,
   *     so no reachFrom/via: the engine warns when the two are combined)
   */
  /**
   * Verifies the builder's reference definition still loads without a single
   * issue, which is its contract with the engine.
   */
  @IsTest
  static void builderContractDefinitionLoadsClean() {
    String definition =
      '{"sections":[' +
      '{"name":"Header","label":"Header","sectionType":"Fixed",' +
      '"targetObject":"Case","recordFilter":"IsClosed = false","rules":[' +
      '{"name":"Email","label":"Applicant Email","jsonPath":"applicant.email",' +
      '"targetField":"SuppliedEmail",' +
      '"overwritePolicy":"Only if blank","minGrade":"Inferred",' +
      '"minConfidence":0.6,"confidenceWeight":2,"required":true,' +
      '"anchorFilter":"IsClosed = false","active":true},' +
      '{"name":"Stamp","label":"Reviewer Stamp","jsonPath":"applicant.reviewer",' +
      '"targetField":"Description","mode":"Custom",' +
      '"handlerClass":"IdpConfigLoaderTest.ContractHandler","active":true}' +
      ']},' +
      '{"name":"Applicant","label":"Applicant Account","sectionType":"Fixed",' +
      '"targetObject":"Account","reachFrom":"Header","via":"Case.AccountId",' +
      '"hop":"Parent","whenNoAnchor":"Create","rules":[' +
      '{"name":"AcctName","jsonPath":"applicant.name","targetField":"Name",' +
      '"overwritePolicy":"Only if blank"}' +
      ']},' +
      '{"name":"OwnerLink","label":"Applicant Owner","sectionType":"Fixed",' +
      '"targetObject":"User","reachFrom":"Applicant","via":"Account.OwnerId",' +
      '"hop":"Parent","rules":[]},' +
      '{"name":"OwnerProfile","label":"Owner Profile","sectionType":"Fixed",' +
      '"targetObject":"Profile","reachFrom":"OwnerLink","via":"User.ProfileId",' +
      '"hop":"Parent","rules":[' +
      '{"name":"ProfileName","jsonPath":"applicant.profileNote",' +
      '"targetField":"Name","overwritePolicy":"Only if blank"}' +
      ']},' +
      '{"name":"Lines","label":"Invoice Lines","sectionType":"Repeating",' +
      '"targetObject":"Asset","reachFrom":"Applicant","via":"Asset.AccountId",' +
      '"hop":"Child","rowPath":"lines","matchField":"SerialNumber",' +
      '"matchValue":"INV-{json:invoiceNumber}-{row:number}",' +
      '"unmatchedRows":"Create","rules":[' +
      '{"name":"LineQty","jsonPath":"quantity","targetField":"Quantity",' +
      '"overwritePolicy":"Always"}' +
      ']},' +
      '{"name":"Warranties","label":"Asset Warranties","sectionType":"Repeating",' +
      '"targetObject":"Asset","rowPath":"warranties","matchField":"SerialNumber",' +
      '"matchValue":"WAR-{row:index}","rowScope":"None","rules":[' +
      '{"name":"WarrantyNote","jsonPath":"note","targetField":"Description",' +
      '"overwritePolicy":"Only if blank"}' +
      ']}' +
      ']}';

    List<IdpResult.Finding> findings = IdpConfigLoader.validateDefinition(
      'Builder_Contract_Set',
      definition
    );
    Assert.areEqual(
      0,
      findings.size(),
      'the builder\'s reference definition must load clean: ' + findings
    );
  }
}
