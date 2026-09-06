/**
 * Engine-level tests for explicit relationship navigation (reachFrom /
 * via / hop): two sections reaching two different Accounts of one record
 * through two lookups, an implicit target that is ambiguous being
 * reported rather than guessed, chains through named sections, child
 * hops, created anchors linked in either direction, and row scoping
 * through a chosen lookup. Config is injected the way the other engine
 * tests do it — Raw* DTOs through the real loader, priming the cache.
 *
 * Asset is the standard object of choice because it carries three
 * lookups to Account (AccountId, AssetProvidedById, AssetServicedById):
 * exactly the shape the naming convention used to paper over.
 */
@IsTest
private class IdpNavigationTest {
  private static final String SET_NAME = 'Navigation_Test_Set';

  private static IdpConfigLoader.RawSection section(
    String name,
    String targetObject
  ) {
    IdpConfigLoader.RawSection raw = new IdpConfigLoader.RawSection();
    raw.name = name;
    raw.label = name;
    raw.sectionType = 'Fixed';
    raw.targetObject = targetObject;
    return raw;
  }

  private static IdpConfigLoader.RawSection section(
    String name,
    String targetObject,
    String reachFrom,
    String via
  ) {
    IdpConfigLoader.RawSection raw = section(name, targetObject);
    raw.reachFrom = reachFrom;
    raw.via = via;
    return raw;
  }

  private static IdpConfigLoader.RawRule rule(
    String name,
    String jsonPath,
    String targetField
  ) {
    IdpConfigLoader.RawRule raw = new IdpConfigLoader.RawRule();
    raw.name = name;
    raw.label = name;
    raw.jsonPath = jsonPath;
    raw.targetField = targetField;
    raw.overwritePolicy = 'Always';
    return raw;
  }

  private static IdpConfigLoader.SetConfig install(
    List<IdpConfigLoader.RawSection> sections
  ) {
    IdpConfigLoader.RawSet rawSet = new IdpConfigLoader.RawSet();
    rawSet.name = SET_NAME;
    rawSet.label = SET_NAME;
    IdpConfigLoader.SetConfig config = IdpConfigLoader.assemble(
      rawSet,
      JSON.serialize(new Map<String, Object>{ 'sections' => sections }),
      new Map<String, IdpValueTypes.Config>()
    );
    IdpConfigLoader.cache.put(SET_NAME, config);
    return config;
  }

  private static IdpResult.Result runOne(
    Id contentDocumentId,
    String jsonString,
    String mode
  ) {
    IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
    work.contentDocumentId = contentDocumentId;
    work.jsonString = jsonString;
    return IdpMappingEngine.run(
      new List<IdpMappingEngine.DocumentWork>{ work },
      SET_NAME,
      mode,
      null
    )[0];
  }

  private static Boolean hasFinding(IdpResult.Result result, String code) {
    return !result.findingsWith(code).isEmpty();
  }

  /** An Asset owned by one Account and serviced by another, with a file
   *  linked to the Asset — the "two lookups to the same object" shape. */
  private class ServicedAsset {
    public Account owner;
    public Account servicer;
    public Asset asset;
    public Id contentDocumentId;
  }

  private static ServicedAsset servicedAsset() {
    ServicedAsset data = new ServicedAsset();
    data.owner = new Account(Name = 'Owner');
    data.servicer = new Account(Name = 'Servicer');
    insert new List<Account>{ data.owner, data.servicer };
    data.asset = new Asset(
      Name = 'Money market fund',
      AccountId = data.owner.Id,
      AssetServicedById = data.servicer.Id
    );
    insert data.asset;
    data.contentDocumentId = IdpTestData.linkFile(data.asset.Id, 'Statement');
    return data;
  }

  private static final String TWO_PHONES = '{"owner":{"phone":"0110000001"},"servicer":{"phone":"0110000002"}}';

  // ───────────────── several lookups to one object ────────────────

  @IsTest
  static void twoSectionsReachTwoAccountsThroughTwoLookups() {
    ServicedAsset data = servicedAsset();
    IdpConfigLoader.RawSection owner = section(
      'Owner',
      'Account',
      'Asset',
      'AccountId'
    );
    owner.rules.add(rule('O1', 'owner.phone', 'Phone'));
    IdpConfigLoader.RawSection servicer = section(
      'Servicer',
      'Account',
      'Asset',
      'AssetServicedById'
    );
    servicer.rules.add(rule('S1', 'servicer.phone', 'Phone'));
    IdpConfigLoader.SetConfig config = install(
      new List<IdpConfigLoader.RawSection>{ owner, servicer }
    );
    Assert.areEqual(0, config.issues.size(), JSON.serialize(config.issues));

    Test.startTest();
    Integer before = Limits.getQueries();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      TWO_PHONES,
      'Extraction'
    );
    Integer used = Limits.getQueries() - before;
    Test.stopTest();

    Assert.isTrue(result.success, JSON.serialize(result.findings));
    Assert.areEqual(2, result.fieldsApplied);
    Map<Id, Account> accounts = new Map<Id, Account>(
      [
        SELECT Phone
        FROM Account
        WHERE Id IN :new List<Id>{ data.owner.Id, data.servicer.Id }
      ]
    );
    Assert.areEqual('0110000001', accounts.get(data.owner.Id).Phone);
    Assert.areEqual('0110000002', accounts.get(data.servicer.Id).Phone);
    Assert.isTrue(
      used <= 4,
      'links + asset root + one grouped fetch per explicit section; used ' +
      used
    );
  }

  @IsTest
  static void anImplicitTargetWithSeveralLookupsIsReportedNotGuessed() {
    ServicedAsset data = servicedAsset();
    IdpConfigLoader.RawSection customer = section('Customer', 'Account');
    customer.rules.add(rule('C1', 'owner.phone', 'Phone'));
    install(new List<IdpConfigLoader.RawSection>{ customer });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      TWO_PHONES,
      'Extraction'
    );
    Test.stopTest();

    Assert.isFalse(result.success);
    List<IdpResult.Finding> ambiguous = result.findingsWith(
      IdpResult.CODE_AMBIGUOUS_RELATIONSHIP
    );
    Assert.areEqual(1, ambiguous.size(), JSON.serialize(result.findings));
    Assert.isTrue(
      ambiguous[0].message.contains('AssetServicedById') &&
      ambiguous[0].message.contains('AccountId'),
      'the candidates are named: ' + ambiguous[0].message
    );
    Assert.isTrue(ambiguous[0].message.contains('reachFrom'));
    Assert.isFalse(hasFinding(result, IdpResult.CODE_UNREACHABLE_TARGET));
    Assert.isNull(
      [SELECT Phone FROM Account WHERE Id = :data.owner.Id].Phone,
      'nothing was written to a guessed Account'
    );
  }

  @IsTest
  static void unscopedRowsUnderAnAmbiguousParentAreReportedNotRun() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    insert new Asset(
      Name = 'Line one',
      AccountId = data.account.Id,
      SerialNumber = 'INV-1'
    );
    IdpConfigLoader.RawSection customer = section('Customer', 'Account');
    customer.rules.add(rule('C1', 'Invoice', 'Description'));
    IdpConfigLoader.RawSection lines = new IdpConfigLoader.RawSection();
    lines.name = 'Lines';
    lines.label = 'Lines';
    lines.sectionType = 'Repeating';
    lines.targetObject = 'Asset';
    lines.rowPath = 'Details';
    lines.matchField = 'SerialNumber';
    lines.matchValue = 'INV-{row:number}';
    lines.rules.add(rule('L1', 'Quantity', 'Quantity'));
    install(new List<IdpConfigLoader.RawSection>{ customer, lines });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"Invoice":"A1","Details":[{"Quantity":3}]}',
      'Extraction'
    );
    Test.stopTest();

    Assert.isTrue(
      hasFinding(result, IdpResult.CODE_AMBIGUOUS_RELATIONSHIP),
      JSON.serialize(result.findings)
    );
    Assert.areEqual(0, result.rowsMatched, 'rows never run unscoped');
    Assert.isNull(
      [SELECT Quantity FROM Asset WHERE SerialNumber = 'INV-1'].Quantity
    );
  }

  // ─────────────────── chains, directions, roots ──────────────────

  @IsTest
  static void twoLookupsToDifferentObjectsFromOneSection() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    Contact person = new Contact(
      LastName = 'Signatory',
      AccountId = data.account.Id
    );
    insert person;
    data.caseRecord.ContactId = person.Id;
    update data.caseRecord;

    IdpConfigLoader.RawSection application = section('Application', 'Case');
    application.rules.add(rule('A1', 'reference', 'Subject'));
    IdpConfigLoader.RawSection holder = section(
      'Holder',
      'Account',
      'Application',
      'AccountId'
    );
    holder.rules.add(rule('H1', 'holder.phone', 'Phone'));
    IdpConfigLoader.RawSection signatory = section(
      'Signatory',
      'Contact',
      'Application',
      'ContactId'
    );
    signatory.rules.add(rule('S1', 'signatory.email', 'Email'));
    install(
      new List<IdpConfigLoader.RawSection>{ application, holder, signatory }
    );

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"reference":"APP-1","holder":{"phone":"0110000009"},"signatory":{"email":"s@example.com"}}',
      'Extraction'
    );
    Test.stopTest();

    Assert.isTrue(result.success, JSON.serialize(result.findings));
    Assert.areEqual(3, result.fieldsApplied);
    Assert.areEqual(
      '0110000009',
      [SELECT Phone FROM Account WHERE Id = :data.account.Id].Phone
    );
    Assert.areEqual(
      's@example.com',
      [SELECT Email FROM Contact WHERE Id = :person.Id].Email
    );
  }

  @IsTest
  static void explicitChildHopFromARootObjectTakesTheNewestChild() {
    Account account = new Account(Name = 'Holder');
    insert account;
    Asset older = new Asset(Name = 'Old', AccountId = account.Id);
    insert older;
    Asset newer = new Asset(Name = 'New', AccountId = account.Id);
    insert newer;
    Test.setCreatedDate(older.Id, Datetime.now().addDays(-2));
    Test.setCreatedDate(newer.Id, Datetime.now().addDays(-1));
    Id fileId = IdpTestData.linkFile(account.Id, 'Statement');

    // reachFrom names a root object, not a section; Asset.AccountId is
    // on the target, so this is a child hop.
    IdpConfigLoader.RawSection holding = section(
      'Holding',
      'Asset',
      'Account',
      'AccountId'
    );
    holding.rules.add(rule('H1', 'holding.name', 'Description'));
    IdpConfigLoader.SetConfig config = install(
      new List<IdpConfigLoader.RawSection>{ holding }
    );
    Assert.isTrue(config.sections[0].childHop);

    Test.startTest();
    IdpResult.Result result = runOne(
      fileId,
      '{"holding":{"name":"Renamed"}}',
      'Extraction'
    );
    Test.stopTest();

    Assert.isTrue(result.success, JSON.serialize(result.findings));
    Assert.areEqual(
      'Renamed',
      [SELECT Description FROM Asset WHERE Id = :newer.Id].Description,
      'the newest child wins'
    );
    Assert.isNull(
      [SELECT Description FROM Asset WHERE Id = :older.Id].Description
    );
  }

  @IsTest
  static void anEmptyLookupIsUnreachableAndSaysWhichHop() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile(); // no ContactId
    IdpConfigLoader.RawSection signatory = section(
      'Signatory',
      'Contact',
      'Case',
      'ContactId'
    );
    signatory.rules.add(rule('S1', 'signatory.email', 'Email'));
    install(new List<IdpConfigLoader.RawSection>{ signatory });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"signatory":{"email":"s@example.com"}}',
      'Extraction'
    );
    Test.stopTest();

    List<IdpResult.Finding> unreachable = result.findingsWith(
      IdpResult.CODE_UNREACHABLE_TARGET
    );
    Assert.areEqual(1, unreachable.size(), JSON.serialize(result.findings));
    Assert.isTrue(
      unreachable[0].message.contains('Case via ContactId'),
      unreachable[0].message
    );
  }

  @IsTest
  static void anUnresolvedSourceIsReportedForFixedAndRepeatingSections() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    // Neither an Opportunity root nor a way to reach one exists here.
    IdpConfigLoader.RawSection holder = section(
      'Holder',
      'Account',
      'Opportunity',
      'AccountId'
    );
    holder.rules.add(rule('H1', 'holder.phone', 'Phone'));
    IdpConfigLoader.RawSection lines = new IdpConfigLoader.RawSection();
    lines.name = 'Lines';
    lines.label = 'Lines';
    lines.sectionType = 'Repeating';
    lines.targetObject = 'Asset';
    lines.rowPath = 'Details';
    lines.matchField = 'SerialNumber';
    lines.matchValue = 'INV-{row:number}';
    // Asset.ContactId is a real lookup, but this Case has no Contact.
    lines.reachFrom = 'Contact';
    lines.via = 'ContactId';
    lines.rules.add(rule('L1', 'Quantity', 'Quantity'));
    install(new List<IdpConfigLoader.RawSection>{ holder, lines });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"holder":{"phone":"1"},"Details":[{"Quantity":3}]}',
      'Extraction'
    );
    Test.stopTest();

    List<IdpResult.Finding> unreachable = result.findingsWith(
      IdpResult.CODE_UNREACHABLE_TARGET
    );
    Assert.areEqual(1, unreachable.size(), JSON.serialize(result.findings));
    Assert.isTrue(unreachable[0].message.contains('"Opportunity"'));
    Assert.areEqual(
      1,
      result.findingsWith(IdpResult.CODE_ROW_LOOKUP_FAILED).size(),
      'rows scoped to an unresolved source are skipped, never run unscoped'
    );
    Assert.areEqual(0, result.rowsMatched);
  }

  @IsTest
  static void rowScopeNoneMatchesRowsByKeyAlone() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    insert new Asset(
      Name = 'Line one',
      AccountId = data.account.Id,
      SerialNumber = 'INV-1'
    );
    IdpConfigLoader.RawSection lines = new IdpConfigLoader.RawSection();
    lines.name = 'Lines';
    lines.label = 'Lines';
    lines.sectionType = 'Repeating';
    lines.targetObject = 'Asset'; // three lookups to the resolved Account
    lines.rowPath = 'Details';
    lines.matchField = 'SerialNumber';
    lines.matchValue = 'INV-{row:number}';
    lines.rowScope = 'None';
    lines.rules.add(rule('L1', 'Quantity', 'Quantity'));
    install(new List<IdpConfigLoader.RawSection>{ lines });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"Details":[{"Quantity":3}]}',
      'Extraction'
    );
    Test.stopTest();

    Assert.isTrue(result.success, JSON.serialize(result.findings));
    Assert.areEqual(1, result.rowsMatched);
    Assert.areEqual(
      3,
      [SELECT Quantity FROM Asset WHERE SerialNumber = 'INV-1']
        .Quantity.intValue()
    );
  }

  @IsTest
  static void multiSegmentViaCrossesAnUntargetedIntermediate() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    Account employer = new Account(Name = 'Employer');
    insert employer;
    Contact person = new Contact(LastName = 'Signer', AccountId = employer.Id);
    insert person;
    data.caseRecord.ContactId = person.Id;
    update data.caseRecord;

    // Case → ContactId → Contact → AccountId → the contact's employer,
    // not the Case's own Account.
    IdpConfigLoader.RawSection employerSection = section(
      'Employer',
      'Account',
      'Case',
      'ContactId.AccountId'
    );
    employerSection.rules.add(rule('E1', 'employer.phone', 'Phone'));
    IdpConfigLoader.SetConfig config = install(
      new List<IdpConfigLoader.RawSection>{ employerSection }
    );
    Assert.areEqual(0, config.issues.size(), JSON.serialize(config.issues));

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"employer":{"phone":"0110000077"}}',
      'Extraction'
    );
    Test.stopTest();

    Assert.isTrue(result.success, JSON.serialize(result.findings));
    Assert.areEqual(
      '0110000077',
      [SELECT Phone FROM Account WHERE Id = :employer.Id].Phone
    );
    Assert.areEqual(
      '0821234567',
      [SELECT Phone FROM Account WHERE Id = :data.account.Id].Phone,
      'the Case\'s own Account was not touched'
    );
  }

  // ───────────────────── creating and linking ─────────────────────

  @IsTest
  static void aCreatedAnchorOnAParentHopBackLinksItsSource() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile(); // no ContactId
    IdpConfigLoader.RawSection signatory = section(
      'Signatory',
      'Contact',
      'Case',
      'ContactId'
    );
    signatory.whenNoAnchor = 'Create';
    signatory.rules.add(rule('S1', 'signatory.lastName', 'LastName'));
    install(new List<IdpConfigLoader.RawSection>{ signatory });

    Test.startTest();
    IdpResult.Result preview = runOne(
      data.contentDocumentId,
      '{"signatory":{"lastName":"Signer"}}',
      'Preview'
    );
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"signatory":{"lastName":"Signer"}}',
      'Extraction'
    );
    Test.stopTest();

    List<IdpResult.Finding> planned = preview.findingsWith(
      IdpResult.CODE_ANCHOR_CREATED
    );
    Assert.areEqual(1, planned.size(), JSON.serialize(preview.findings));
    Assert.isTrue(
      planned[0].message.contains('point Case.ContactId at it'),
      planned[0].message
    );

    Assert.isTrue(result.success, JSON.serialize(result.findings));
    Assert.areEqual(1, result.createdRecordIds.size());
    Contact created = [
      SELECT Id, LastName
      FROM Contact
      WHERE Id = :result.createdRecordIds[0]
    ];
    Assert.areEqual('Signer', created.LastName);
    Assert.areEqual(
      created.Id,
      [SELECT ContactId FROM Case WHERE Id = :data.caseRecord.Id].ContactId,
      'the source now points at the record the run created'
    );
    Assert.isTrue(
      result.updatedRecordIds.contains(data.caseRecord.Id),
      'the back-link rode the run\'s single update'
    );
  }

  @IsTest
  static void aCreatedAnchorNeedsItsSourceResolved() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpConfigLoader.RawSection signatory = section(
      'Signatory',
      'Contact',
      'Opportunity',
      'ContactId'
    );
    signatory.whenNoAnchor = 'Create';
    signatory.rules.add(rule('S1', 'signatory.lastName', 'LastName'));
    install(new List<IdpConfigLoader.RawSection>{ signatory });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"signatory":{"lastName":"Signer"}}',
      'Extraction'
    );
    Test.stopTest();

    Assert.isTrue(hasFinding(result, IdpResult.CODE_UNREACHABLE_TARGET));
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Contact],
      'no source to link to means nothing is created'
    );
  }

  @IsTest
  static void rowsScopedThroughAChosenLookupIgnoreTheOtherAccountsRows() {
    ServicedAsset data = servicedAsset(); // asset serviced by 'Servicer'
    // A second asset the servicer owns outright, sharing the serial.
    insert new Asset(
      Name = 'Owned by servicer',
      AccountId = data.servicer.Id,
      SerialNumber = 'SN-1'
    );
    data.asset.SerialNumber = 'SN-1';
    update data.asset;

    IdpConfigLoader.RawSection servicer = section(
      'Servicer',
      'Account',
      'Asset',
      'AssetServicedById'
    );
    servicer.rules.add(rule('S1', 'servicer.phone', 'Phone'));
    IdpConfigLoader.RawSection lines = new IdpConfigLoader.RawSection();
    lines.name = 'Serviced';
    lines.label = 'Serviced';
    lines.sectionType = 'Repeating';
    lines.targetObject = 'Asset';
    lines.rowPath = 'lines';
    lines.matchField = 'SerialNumber';
    lines.matchValue = '{row:serial}';
    lines.reachFrom = 'Servicer';
    lines.via = 'AssetServicedById';
    lines.rules.add(rule('L1', 'note', 'Description'));
    install(new List<IdpConfigLoader.RawSection>{ servicer, lines });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"servicer":{"phone":"0110000002"},"lines":[{"serial":"SN-1","note":"serviced"}]}',
      'Extraction'
    );
    Test.stopTest();

    Assert.isTrue(result.success, JSON.serialize(result.findings));
    Assert.areEqual(1, result.rowsMatched);
    Assert.areEqual(
      'serviced',
      [SELECT Description FROM Asset WHERE Id = :data.asset.Id].Description,
      'the row matched the asset serviced by the account'
    );
    Assert.isNull(
      [SELECT Description FROM Asset WHERE Name = 'Owned by servicer']
      .Description,
      'the asset merely owned by that account, same serial, was not touched'
    );
  }
}
