/**
 * Integration tests for the engine: every v1 scenario ported (extraction,
 * only-if-blank, compliance, repeating sections, unmatched and duplicate
 * keys, per-rule mode, handler DI) plus the v2 behaviours — Preview,
 * both-sides compliance canonicalization, grade and confidence gates, and
 * the bulk query budget.
 *
 * Config is injected by assembling Raw* DTOs through the real loader
 * validation and priming the loader cache.
 */
@IsTest
private class IdpMappingEngineTest {
  private static final String SET_NAME = 'Engine_Test_Set';

  // ───────────────────────── config helpers ───────────────────────

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

  /**
   * A rule plus the section it belongs to. Rules live nested inside their
   * section in the real config; this wrapper lets each test keep listing
   * them flatly, which reads better when a case is about one rule.
   */
  private class Spec {
    private String sectionName;
    private IdpConfigLoader.RawRule rule;
  }

  private static Spec rule(
    String name,
    String sectionName,
    String jsonPath,
    String targetObject,
    String targetField
  ) {
    IdpConfigLoader.RawRule raw = new IdpConfigLoader.RawRule();
    raw.name = name;
    raw.label = name;
    raw.jsonPath = jsonPath;
    raw.targetField = targetField;
    raw.overwritePolicy = 'Always';
    Spec spec = new Spec();
    spec.sectionName = sectionName;
    spec.rule = raw;
    return spec;
  }

  private static void install(
    List<IdpConfigLoader.RawSection> sections,
    List<Spec> rules,
    Map<String, IdpValueTypes.Config> valueTypes
  ) {
    Map<String, IdpConfigLoader.RawSection> byName = new Map<String, IdpConfigLoader.RawSection>();
    for (IdpConfigLoader.RawSection section : sections) {
      byName.put(section.name, section);
    }
    for (Spec spec : rules) {
      IdpConfigLoader.RawSection section = byName.get(spec.sectionName);
      if (section != null) {
        section.rules.add(spec.rule);
      }
    }
    IdpConfigLoader.RawSet rawSet = new IdpConfigLoader.RawSet();
    rawSet.name = SET_NAME;
    rawSet.label = SET_NAME;
    IdpConfigLoader.cache.put(
      SET_NAME,
      IdpConfigLoader.assemble(
        rawSet,
        JSON.serialize(new Map<String, Object>{ 'sections' => sections }),
        valueTypes
      )
    );
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

  private static String estateJson(String name, String phone) {
    return JSON.serialize(
      new Map<String, Object>{
        'applicant' => new Map<String, Object>{
          'name' => name,
          'phone' => phone
        },
        'estate' => new Map<String, Object>{
          'description' => 'Captured from scanned form'
        }
      }
    );
  }

  private static void installEstateConfig() {
    install(
      new List<IdpConfigLoader.RawSection>{
        section('Case_Details', 'Case'),
        section('Customer', 'Account')
      },
      new List<Spec>{
        rule(
          'R1_Name',
          'Case_Details',
          'applicant.name',
          'Case',
          'SuppliedName'
        ),
        rule(
          'R2_Description',
          'Case_Details',
          'estate.description',
          'Case',
          'Description'
        ),
        rule(
          'R3_Missing',
          'Case_Details',
          'applicant.missing',
          'Case',
          'SuppliedEmail'
        ),
        phoneRule('R4_Phone', 'Only if blank')
      },
      new Map<String, IdpValueTypes.Config>()
    );
  }

  private static Spec phoneRule(String name, String policy) {
    Spec raw = rule(name, 'Customer', 'applicant.phone', 'Account', 'Phone');
    raw.rule.overwritePolicy = policy;
    return raw;
  }

  /** A single Fixed section whose anchor filter reads a document value
   *  ({json:status}), so it resolves through IdpContextResolver's
   *  per-document query paths instead of one grouped query. */
  private static void installDocBoundCaseFilterConfig() {
    IdpConfigLoader.RawSection details = section('Case_Details', 'Case');
    details.recordFilter = 'Status = {json:status}';
    install(
      new List<IdpConfigLoader.RawSection>{ details },
      new List<Spec>{
        rule(
          'R1_Name',
          'Case_Details',
          'applicant.name',
          'Case',
          'SuppliedName'
        )
      },
      new Map<String, IdpValueTypes.Config>()
    );
  }

  // ───────────────────────── extraction ───────────────────────────

  @IsTest
  static void appliesMappingsToReachableRecords() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    installEstateConfig();

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('Jane Doe', '555-NEW'),
      null
    );
    Test.stopTest();

    Assert.isTrue(
      result.success,
      'findings: ' + JSON.serialize(result.findings)
    );
    Assert.isTrue(result.compliant);
    Assert.areEqual(2, result.fieldsApplied, 'name + description');
    Assert.areEqual(1, result.updatedRecordIds.size(), 'only the Case');
    Case updated = [
      SELECT SuppliedName, Description
      FROM Case
      WHERE Id = :data.caseRecord.Id
    ];
    Assert.areEqual('Jane Doe', updated.SuppliedName);
    Assert.areEqual('Captured from scanned form', updated.Description);
    Assert.areEqual(
      '0821234567',
      [SELECT Phone FROM Account WHERE Id = :data.account.Id].Phone,
      'Only-if-blank must not overwrite the existing phone'
    );
  }

  @IsTest
  static void writesBlankFieldUnderOnlyIfBlank() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile('Holder', null);
    installEstateConfig();

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('Jane', '0821234567'),
      null
    );
    Test.stopTest();

    Assert.isTrue(
      result.success,
      'findings: ' + JSON.serialize(result.findings)
    );
    Assert.areEqual(
      '0821234567',
      [SELECT Phone FROM Account WHERE Id = :data.account.Id].Phone
    );
  }

  @IsTest
  static void previewPlansWithoutWriting() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    installEstateConfig();

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('Jane Doe', '555-NEW'),
      'Preview'
    );
    Test.stopTest();

    Assert.isTrue(result.success);
    Assert.areEqual(0, result.fieldsApplied, 'nothing applied in Preview');
    Assert.areEqual(0, result.updatedRecordIds.size());
    Assert.areEqual(2, result.plannedChanges.size());
    Assert.isNull(
      [SELECT SuppliedName FROM Case WHERE Id = :data.caseRecord.Id]
      .SuppliedName,
      'the record is untouched'
    );
    IdpResult.PlannedChange change = result.plannedChanges[0];
    Assert.areEqual('Case', change.objectName);
    Assert.areEqual('Jane Doe', change.newValue);
    Assert.areEqual('Exact', change.grade);
  }

  @IsTest
  static void reportsUnreachableTargetPerSection() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    install(
      new List<IdpConfigLoader.RawSection>{
        section('Nowhere', 'Contact') // no Contact is reachable
      },
      new List<Spec>{
        rule('R1', 'Nowhere', 'applicant.name', 'Contact', 'LastName')
      },
      new Map<String, IdpValueTypes.Config>()
    );

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('J', '1'),
      null
    );
    Test.stopTest();

    Assert.isFalse(result.success);
    Assert.areEqual(
      1,
      result.findingsWith(IdpResult.CODE_UNREACHABLE_TARGET).size()
    );
  }

  // ────────────────────────── gates ───────────────────────────────

  @IsTest
  static void requiredPathMissingIsAnError() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    Spec required = rule(
      'R1',
      'Case_Details',
      'applicant.idNumber',
      'Case',
      'SuppliedName'
    );
    required.rule.required = true;
    install(
      new List<IdpConfigLoader.RawSection>{ section('Case_Details', 'Case') },
      new List<Spec>{ required },
      new Map<String, IdpValueTypes.Config>()
    );

    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('Jane', '1'),
      null
    );
    Assert.isFalse(result.success);
    Assert.areEqual(
      1,
      result.findingsWith(IdpResult.CODE_REQUIRED_MISSING).size()
    );
  }

  @IsTest
  static void ambiguousDateIsReportedNeverGuessed() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpValueTypes.Config dateType = new IdpValueTypes.Config();
    dateType.name = 'Date_Both';
    dateType.kind = IdpValueTypes.KIND_DATE;
    dateType.formats = new List<String>{ 'dd/MM/yyyy', 'MM/dd/yyyy' };

    Spec dateRule = rule(
      'R1',
      'Case_Details',
      'signedDate',
      'Case',
      'Description'
    );
    dateRule.rule.valueTypeName = 'Date_Both';
    install(
      new List<IdpConfigLoader.RawSection>{ section('Case_Details', 'Case') },
      new List<Spec>{ dateRule },
      new Map<String, IdpValueTypes.Config>{ 'Date_Both' => dateType }
    );

    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"signedDate": "03/04/2024"}',
      null
    );
    Assert.isTrue(result.success, 'ambiguity is a warning, not an error');
    Assert.areEqual(
      1,
      result.findingsWith(IdpResult.CODE_PARSE_AMBIGUOUS).size()
    );
    Assert.areEqual(0, result.fieldsApplied, 'nothing was written');
  }

  @IsTest
  static void minGradeExactBlocksHeuristicParses() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpValueTypes.Config money = new IdpValueTypes.Config();
    money.name = 'Money_Test';
    money.kind = IdpValueTypes.KIND_NUMBER;

    Spec strict = rule(
      'R1',
      'Customer',
      'turnover',
      'Account',
      'AnnualRevenue'
    );
    strict.rule.valueTypeName = 'Money_Test';
    strict.rule.minGrade = 'Exact';
    install(
      new List<IdpConfigLoader.RawSection>{ section('Customer', 'Account') },
      new List<Spec>{ strict },
      new Map<String, IdpValueTypes.Config>{ 'Money_Test' => money }
    );

    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"turnover": "1,234"}', // INFERRED without a locale
      null
    );
    Assert.areEqual(
      1,
      result.findingsWith(IdpResult.CODE_BELOW_MIN_GRADE).size()
    );
    Assert.areEqual(0, result.fieldsApplied);
  }

  @IsTest
  static void confidenceEnvelopeGatesLowConfidenceValues() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    Spec gated = rule(
      'R1',
      'Case_Details',
      'applicant.name',
      'Case',
      'SuppliedName'
    );
    gated.rule.minConfidence = 0.8;
    install(
      new List<IdpConfigLoader.RawSection>{ section('Case_Details', 'Case') },
      new List<Spec>{ gated },
      new Map<String, IdpValueTypes.Config>()
    );

    Test.startTest();
    IdpResult.Result low = runOne(
      data.contentDocumentId,
      '{"applicant": {"name": {"value": "Jane", "confidence": 0.4}}}',
      null
    );
    IdpResult.Result high = runOne(
      data.contentDocumentId,
      '{"applicant": {"name": {"value": "Jane", "confidence": 0.95}}}',
      null
    );
    Test.stopTest();

    Assert.areEqual(1, low.findingsWith(IdpResult.CODE_LOW_CONFIDENCE).size());
    Assert.areEqual(0, low.fieldsApplied);
    Assert.areEqual(1, high.fieldsApplied);
    Assert.areEqual(
      'Jane',
      [SELECT SuppliedName FROM Case WHERE Id = :data.caseRecord.Id]
      .SuppliedName
    );
  }

  // ───────────────────────── compliance ───────────────────────────

  @IsTest
  static void complianceCanonicalizesBothSides() {
    // Stored national format, document international — v1 reported a false
    // mismatch here; v2 canonicalizes both sides through the value type.
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile(
      'Holder',
      '082 123 4567'
    );
    IdpValueTypes.Config phoneZa = new IdpValueTypes.Config();
    phoneZa.name = 'Phone_ZA';
    phoneZa.kind = IdpValueTypes.KIND_PHONE;
    phoneZa.region = 'ZA';

    Spec phone = phoneRule('R1_Phone', 'Always');
    phone.rule.valueTypeName = 'Phone_ZA';
    install(
      new List<IdpConfigLoader.RawSection>{ section('Customer', 'Account') },
      new List<Spec>{ phone },
      new Map<String, IdpValueTypes.Config>{ 'Phone_ZA' => phoneZa }
    );

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('Jane', '+27 82 123 4567'),
      'Compliance'
    );
    Test.stopTest();

    Assert.isTrue(result.success);
    Assert.isTrue(
      result.compliant,
      'formats differ, the number does not: ' + JSON.serialize(result.findings)
    );
    Assert.areEqual(1, result.fieldsCompared);
    Assert.areEqual(
      0,
      result.updatedRecordIds.size(),
      'compliance never writes'
    );
  }

  @IsTest
  static void complianceReportsMismatchAndNear() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    update new Case(
      Id = data.caseRecord.Id,
      SuppliedName = 'Someone Else',
      Description = null
    );
    installEstateConfig();

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('Jane Doe', '+27 82 123 4567'),
      'Compliance'
    );
    Test.stopTest();

    Assert.isTrue(
      result.success,
      'mismatches are data, not failures: ' + JSON.serialize(result.findings)
    );
    Assert.isFalse(result.compliant);
    List<IdpResult.Finding> mismatches = result.findingsWith(
      IdpResult.CODE_VALUE_MISMATCH
    );
    Assert.areEqual(
      2,
      mismatches.size(),
      'wrong name + blank description (a blank field cannot confirm the document)'
    );
    Assert.areEqual('Jane Doe', mismatches[0].extractedValue);
    Assert.areEqual('Someone Else', mismatches[0].storedValue);
    Assert.areEqual(
      1,
      result.findingsWith(IdpResult.CODE_VALUE_NEAR).size(),
      'same subscriber number, unprovable country code — Near, not Mismatch'
    );
  }

  @IsTest
  static void perRuleModeMixesExtractionAndCompliance() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    Spec extract = rule(
      'R1_Extract',
      'Case_Details',
      'estate.description',
      'Case',
      'Description'
    );
    Spec verify = rule(
      'R2_Verify',
      'Case_Details',
      'applicant.name',
      'Case',
      'SuppliedName'
    );
    verify.rule.mode = 'Compliance';
    install(
      new List<IdpConfigLoader.RawSection>{ section('Case_Details', 'Case') },
      new List<Spec>{ extract, verify },
      new Map<String, IdpValueTypes.Config>()
    );

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('Jane Doe', '1'),
      'Extraction'
    );
    Test.stopTest();

    Assert.areEqual(1, result.fieldsApplied, 'description extracted');
    Assert.areEqual(1, result.fieldsCompared, 'name verified');
    Assert.isFalse(result.compliant, 'blank stored name is a mismatch');
  }

  @IsTest
  static void findingHandlerCreatesTaskAndFailuresAreReported() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    update new Case(Id = data.caseRecord.Id, SuppliedName = 'Someone Else');
    installEstateConfig();

    IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
    work.contentDocumentId = data.contentDocumentId;
    work.jsonString = estateJson('Jane Doe', '0821234567');

    Test.startTest();
    IdpResult.Result handled = IdpMappingEngine.run(
      new List<IdpMappingEngine.DocumentWork>{ work },
      SET_NAME,
      'Compliance',
      'IdpComplianceTaskHandler'
    )[0];

    IdpMappingEngine.DocumentWork second = new IdpMappingEngine.DocumentWork();
    second.contentDocumentId = data.contentDocumentId;
    second.jsonString = estateJson('Jane Doe', '0821234567');
    IdpResult.Result broken = IdpMappingEngine.run(
      new List<IdpMappingEngine.DocumentWork>{ second },
      SET_NAME,
      'Compliance',
      'NoSuchHandlerClass'
    )[0];
    Test.stopTest();

    Assert.isFalse(handled.compliant);
    List<Task> tasks = [
      SELECT Subject, WhatId, Description
      FROM Task
      WHERE Subject = 'Review compliance mismatches'
    ];
    Assert.areEqual(1, tasks.size());
    Assert.areEqual(data.caseRecord.Id, tasks[0].WhatId);
    Assert.isTrue(tasks[0].Description.contains('Jane Doe'));

    Assert.areEqual(
      1,
      broken.findingsWith(IdpResult.CODE_HANDLER_FAILED).size()
    );
  }

  // ─────────────────────── repeating sections ─────────────────────

  private static void installInvoiceConfig() {
    IdpConfigLoader.RawSection lines = new IdpConfigLoader.RawSection();
    lines.name = 'Lines';
    lines.label = 'Lines';
    lines.sectionType = 'Repeating';
    lines.targetObject = 'Asset';
    lines.rowPath = 'Details';
    lines.matchField = 'SerialNumber';
    lines.matchValue = 'INV-{json:Invoice}-{row:number}';
    install(
      new List<IdpConfigLoader.RawSection>{ lines },
      new List<Spec>{
        rule('L1_Quantity', 'Lines', 'Quantity', 'Asset', 'Quantity'),
        rule('L2_Name', 'Lines', 'Description', 'Asset', 'Name')
      },
      new Map<String, IdpValueTypes.Config>()
    );
  }

  private static String invoiceJson(List<Map<String, Object>> details) {
    return JSON.serialize(
      new Map<String, Object>{ 'Invoice' => 'A1', 'Details' => details }
    );
  }

  @IsTest
  static void repeatingSectionMatchesAndUpdatesRows() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    insert new List<Asset>{
      new Asset(
        Name = 'Line one',
        AccountId = data.account.Id,
        SerialNumber = 'INV-A1-1'
      ),
      new Asset(
        Name = 'Line two',
        AccountId = data.account.Id,
        SerialNumber = 'INV-A1-2'
      )
    };
    installInvoiceConfig();

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      invoiceJson(
        new List<Map<String, Object>>{
          new Map<String, Object>{
            'Quantity' => 3,
            'Description' => 'Widgets'
          },
          new Map<String, Object>{
            'Quantity' => 5,
            'Description' => 'Sprockets'
          },
          new Map<String, Object>{
            'Quantity' => 9,
            'Description' => 'Ghost row'
          }
        }
      ),
      null
    );
    Test.stopTest();

    Assert.areEqual(2, result.rowsMatched, JSON.serialize(result.findings));
    Assert.areEqual(2, result.rowsUpdated);
    Assert.areEqual(4, result.fieldsApplied, 'two fields per matched row');
    Assert.areEqual(
      new List<String>{ 'INV-A1-3' },
      result.unmatchedRowKeys,
      'the third document row has no record — reported, not created'
    );
    Assert.areEqual(
      3,
      [SELECT Quantity FROM Asset WHERE SerialNumber = 'INV-A1-1'][0]
        .Quantity.intValue()
    );
    Assert.areEqual(
      'Sprockets',
      [SELECT Name FROM Asset WHERE SerialNumber = 'INV-A1-2'][0].Name
    );
  }

  @IsTest
  static void duplicateRowKeysAreSkippedAndReported() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    insert new Asset(
      Name = 'Line',
      AccountId = data.account.Id,
      SerialNumber = 'INV-A1-1'
    );
    IdpConfigLoader.RawSection lines = new IdpConfigLoader.RawSection();
    lines.name = 'Lines';
    lines.label = 'Lines';
    lines.sectionType = 'Repeating';
    lines.targetObject = 'Asset';
    lines.rowPath = 'Details';
    lines.matchValue = 'INV-{json:Invoice}-{row:Ref}';
    lines.matchField = 'SerialNumber';
    install(
      new List<IdpConfigLoader.RawSection>{ lines },
      new List<Spec>{ rule('L1', 'Lines', 'Quantity', 'Asset', 'Quantity') },
      new Map<String, IdpValueTypes.Config>()
    );

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      invoiceJson(
        new List<Map<String, Object>>{
          new Map<String, Object>{ 'Ref' => 1, 'Quantity' => 3 },
          new Map<String, Object>{ 'Ref' => 1, 'Quantity' => 7 }
        }
      ),
      null
    );
    Test.stopTest();

    Assert.areEqual(
      1,
      result.findingsWith(IdpResult.CODE_ROW_DUPLICATE_KEY).size()
    );
    Assert.areEqual(1, result.rowsMatched, 'only the first row applied');
    Assert.areEqual(
      3,
      [SELECT Quantity FROM Asset WHERE SerialNumber = 'INV-A1-1'][0]
        .Quantity.intValue(),
      'the duplicate must not overwrite the first row'
    );
  }

  // ──────────────────────── bulk behaviour ────────────────────────

  @IsTest
  static void threeDocumentsShareTheQueryBudget() {
    List<IdpTestData.CaseWithFile> data = new List<IdpTestData.CaseWithFile>{
      IdpTestData.caseWithFile('One', '1'),
      IdpTestData.caseWithFile('Two', '2'),
      IdpTestData.caseWithFile('Three', '3')
    };
    installEstateConfig();

    List<IdpMappingEngine.DocumentWork> works = new List<IdpMappingEngine.DocumentWork>();
    for (Integer i = 0; i < data.size(); i++) {
      IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
      work.contentDocumentId = data[i].contentDocumentId;
      work.jsonString = estateJson('Person ' + i, '555-000' + i);
      works.add(work);
    }

    Test.startTest();
    Integer queriesBefore = Limits.getQueries();
    Integer dmlBefore = Limits.getDmlStatements();
    List<IdpResult.Result> results = IdpMappingEngine.run(
      works,
      SET_NAME,
      null,
      null
    );
    Integer queriesUsed = Limits.getQueries() - queriesBefore;
    Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
    Test.stopTest();

    for (Integer i = 0; i < results.size(); i++) {
      Assert.isTrue(
        results[i].success,
        'doc ' + i + ': ' + JSON.serialize(results[i].findings)
      );
      Assert.areEqual(2, results[i].fieldsApplied);
    }
    Assert.areEqual(
      'Person 2',
      [SELECT SuppliedName FROM Case WHERE Id = :data[2].caseRecord.Id]
      .SuppliedName,
      'each document lands on its own Case'
    );
    Assert.isTrue(
      queriesUsed <= 5,
      'links + cases + accounts (+ describe-free) should stay grouped; used ' +
      queriesUsed
    );
    Assert.areEqual(1, dmlUsed, 'one partial-success update for the whole run');
  }

  /** The bulk query budget at the platform's real batch scope, not the
   *  3-document sample above: query count must stay flat as document
   *  count rises, or every scaling defect this class of test would catch
   *  is invisible below the threshold where it manifests. */
  @IsTest
  static void queryCountStaysFlatAcross200Documents() {
    Integer bulkSize = 200;
    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < bulkSize; i++) {
      accounts.add(new Account(Name = 'Bulk Holder ' + i, Phone = '555-' + i));
    }
    insert accounts;
    List<Case> cases = new List<Case>();
    for (Integer i = 0; i < bulkSize; i++) {
      cases.add(
        new Case(AccountId = accounts[i].Id, Subject = 'Estate intake')
      );
    }
    insert cases;
    installEstateConfig();

    List<IdpMappingEngine.DocumentWork> works = new List<IdpMappingEngine.DocumentWork>();
    for (Integer i = 0; i < bulkSize; i++) {
      IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
      work.seedRecordId = cases[i].Id;
      work.jsonString = estateJson('Person ' + i, '555-100' + i);
      works.add(work);
    }

    Test.startTest();
    Integer queriesBefore = Limits.getQueries();
    List<IdpResult.Result> results = IdpMappingEngine.run(
      works,
      SET_NAME,
      null,
      null
    );
    Integer queriesUsed = Limits.getQueries() - queriesBefore;
    Test.stopTest();

    for (Integer i = 0; i < results.size(); i++) {
      Assert.isTrue(
        results[i].success,
        'doc ' + i + ': ' + JSON.serialize(results[i].findings)
      );
    }
    Assert.isTrue(
      queriesUsed <= 5,
      'query count must not scale with document count at real batch scope; used ' +
      queriesUsed
    );
  }

  /** D-1/D-2 regression: many documents whose anchor filter reads a
   *  document value ({json:status}) but resolve to identical bound values
   *  reuse one query instead of issuing one per document. */
  @IsTest
  static void documentBoundFilterReusesQueriesForSharedValues() {
    Case sharedCase = new Case(Subject = 'Estate intake', Status = 'New');
    insert sharedCase;
    installDocBoundCaseFilterConfig();

    Integer bulkSize = 20;
    List<IdpMappingEngine.DocumentWork> works = new List<IdpMappingEngine.DocumentWork>();
    for (Integer i = 0; i < bulkSize; i++) {
      IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
      work.seedRecordId = sharedCase.Id;
      work.jsonString = JSON.serialize(
        new Map<String, Object>{
          'applicant' => new Map<String, Object>{ 'name' => 'Person ' + i },
          'status' => 'New'
        }
      );
      works.add(work);
    }

    Test.startTest();
    Integer queriesBefore = Limits.getQueries();
    List<IdpResult.Result> results = IdpMappingEngine.run(
      works,
      SET_NAME,
      null,
      null
    );
    Integer queriesUsed = Limits.getQueries() - queriesBefore;
    Test.stopTest();

    for (IdpResult.Result result : results) {
      Assert.isTrue(result.success, JSON.serialize(result.findings));
    }
    Assert.isTrue(
      queriesUsed <= 5,
      '20 documents sharing one filter value must not cost 20 separate per-document queries; used ' +
      queriesUsed
    );
  }

  /** D-2 regression: at real batch scope, a document-bound anchor filter
   *  must defer gracefully (rerunnable, reported) rather than exhaust the
   *  query limit mid-resolution — the headroom estimate now scales with
   *  document count instead of ignoring it. */
  @IsTest
  static void documentBoundFilterDefersInsteadOfExceedingTheQueryLimitAt200Documents() {
    Case sharedCase = new Case(Subject = 'Estate intake', Status = 'New');
    insert sharedCase;
    installDocBoundCaseFilterConfig();

    Integer bulkSize = 200;
    List<IdpMappingEngine.DocumentWork> works = new List<IdpMappingEngine.DocumentWork>();
    for (Integer i = 0; i < bulkSize; i++) {
      IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
      work.seedRecordId = sharedCase.Id;
      work.jsonString = JSON.serialize(
        new Map<String, Object>{
          'applicant' => new Map<String, Object>{ 'name' => 'Person ' + i },
          'status' => 'New'
        }
      );
      works.add(work);
    }

    Test.startTest();
    List<IdpResult.Result> results = IdpMappingEngine.run(
      works,
      SET_NAME,
      null,
      null
    );
    Test.stopTest();

    for (IdpResult.Result result : results) {
      Assert.isTrue(result.deferred, JSON.serialize(result.findings));
      Assert.areEqual(
        1,
        result.findingsWith(IdpResult.CODE_DOC_DEFERRED).size()
      );
    }
  }

  @IsTest
  static void limitsGuardDefersInsteadOfThrowing() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    installEstateConfig();
    IdpLimitsGuard.testQueryHeadroom = 1; // pretend the transaction is spent

    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('J', '1'),
      null
    );
    Assert.isTrue(result.deferred);
    Assert.isFalse(result.success);
    Assert.areEqual(1, result.findingsWith(IdpResult.CODE_DOC_DEFERRED).size());
  }

  // ───────────────────────── input errors ─────────────────────────

  @IsTest
  static void badInputsAreReportedPerDocument() {
    installEstateConfig();
    IdpMappingEngine.DocumentWork noIds = new IdpMappingEngine.DocumentWork();
    noIds.jsonString = '{}';
    IdpMappingEngine.DocumentWork badJson = new IdpMappingEngine.DocumentWork();
    badJson.seedRecordId = UserInfo.getUserId();
    badJson.jsonString = 'not json';

    List<IdpResult.Result> results = IdpMappingEngine.run(
      new List<IdpMappingEngine.DocumentWork>{ noIds, badJson },
      SET_NAME,
      null,
      null
    );
    Assert.areEqual(
      1,
      results[0].findingsWith(IdpResult.CODE_INVALID_INPUT).size()
    );
    Assert.areEqual(
      1,
      results[1].findingsWith(IdpResult.CODE_JSON_INVALID).size()
    );
  }

  @IsTest
  static void unknownModeAndUnknownSetAreErrors() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    installEstateConfig();
    IdpResult.Result badMode = runOne(data.contentDocumentId, '{}', 'Sideways');
    Assert.areEqual(
      1,
      badMode.findingsWith(IdpResult.CODE_INVALID_MODE).size()
    );

    IdpMappingEngine.DocumentWork work = new IdpMappingEngine.DocumentWork();
    work.contentDocumentId = data.contentDocumentId;
    work.jsonString = '{}';
    IdpResult.Result badSet = IdpMappingEngine.run(
      new List<IdpMappingEngine.DocumentWork>{ work },
      'No_Such_Set_Xyz',
      null,
      null
    )[0];
    Assert.isFalse(badSet.success);
    Assert.areEqual(1, badSet.findingsWith(IdpResult.CODE_CONFIG_ISSUE).size());
  }

  // ─────────────────────── invocable surface ──────────────────────

  @IsTest
  static void invocableGroupsRequestsIntoOneRun() {
    IdpTestData.CaseWithFile first = IdpTestData.caseWithFile('A', '1');
    IdpTestData.CaseWithFile second = IdpTestData.caseWithFile('B', '2');
    installEstateConfig();

    IdpMappingInvocable.Request one = new IdpMappingInvocable.Request();
    one.contentDocumentId = first.contentDocumentId;
    one.jsonString = estateJson('First Person', '1');
    one.mappingSetName = SET_NAME;
    IdpMappingInvocable.Request two = new IdpMappingInvocable.Request();
    two.contentDocumentId = second.contentDocumentId;
    two.jsonString = estateJson('Second Person', '2');
    two.mappingSetName = SET_NAME;

    Test.startTest();
    List<IdpResult.Result> results = IdpMappingInvocable.apply(
      new List<IdpMappingInvocable.Request>{ one, two }
    );
    Test.stopTest();

    Assert.areEqual(2, results.size());
    Assert.isTrue(results[0].success && results[1].success);
    Assert.areEqual(
      'First Person',
      [SELECT SuppliedName FROM Case WHERE Id = :first.caseRecord.Id]
      .SuppliedName,
      'results map back to their own requests'
    );
    Assert.areEqual(
      'Second Person',
      [SELECT SuppliedName FROM Case WHERE Id = :second.caseRecord.Id]
      .SuppliedName
    );
  }

  // ─────────────────────── controller surface ─────────────────────

  @IsTest
  static void controllerPreviewAndApplyRoundTrip() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    installEstateConfig();

    Test.startTest();
    IdpResult.Result previewed = IdpMappingController.preview(
      data.contentDocumentId,
      estateJson('Jane Doe', '1'),
      SET_NAME
    );
    IdpResult.Result applied = IdpMappingController.apply(
      data.contentDocumentId,
      estateJson('Jane Doe', '1'),
      SET_NAME,
      null,
      null
    );
    Test.stopTest();

    Assert.areEqual(2, previewed.plannedChanges.size());
    Assert.areEqual(0, previewed.updatedRecordIds.size());
    Assert.areEqual(2, applied.fieldsApplied);
    Assert.areEqual(
      'Jane Doe',
      [SELECT SuppliedName FROM Case WHERE Id = :data.caseRecord.Id]
      .SuppliedName
    );
  }

  @IsTest
  static void aFieldThatDisappearsAfterLoadIsStillReported() {
    // The loader screens field names, so config can no longer produce an
    // unknown field. The evaluator's guard still matters for the case the
    // loader cannot cover: a field deleted between load and evaluation.
    // Reaching it means building the config by hand, past the loader.
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();

    IdpConfigLoader.RuleConfig ghost = new IdpConfigLoader.RuleConfig();
    ghost.name = 'R1_Ghost';
    ghost.label = 'Ghost';
    ghost.jsonPath = 'applicant.name';
    ghost.targetObject = 'Case';
    ghost.targetField = 'Vanished_Field__c';
    ghost.overwritePolicy = 'Always';

    IdpConfigLoader.SectionConfig section = new IdpConfigLoader.SectionConfig();
    section.name = 'Case_Details';
    section.label = 'Case Details';
    section.targetObject = 'Case';
    section.rules.add(ghost);

    IdpConfigLoader.SetConfig config = new IdpConfigLoader.SetConfig();
    config.found = true;
    config.name = SET_NAME;
    config.label = SET_NAME;
    config.sections.add(section);
    IdpConfigLoader.cache.put(SET_NAME, config);

    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('Jane', '1'),
      null
    );
    Assert.areEqual(
      1,
      result.findingsWith(IdpResult.CODE_UNKNOWN_FIELD).size(),
      'the engine reports it rather than failing the document'
    );
    Assert.areEqual(0, result.fieldsApplied);
  }

  @IsTest
  static void unknownFieldsAreReportedPerRule() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    install(
      new List<IdpConfigLoader.RawSection>{ section('Case_Details', 'Case') },
      new List<Spec>{
        rule(
          'R1_Bad',
          'Case_Details',
          'applicant.name',
          'Case',
          'No_Such_Field__c'
        ),
        rule(
          'R2_Good',
          'Case_Details',
          'applicant.name',
          'Case',
          'SuppliedName'
        )
      },
      new Map<String, IdpValueTypes.Config>()
    );

    IdpResult.Result result = runOne(
      data.contentDocumentId,
      estateJson('Jane', '1'),
      null
    );
    // The loader now checks field names against the schema, so a bad name
    // is rejected once when the config loads rather than once per document.
    Assert.areEqual(
      1,
      result.findingsWith(IdpResult.CODE_CONFIG_ISSUE).size(),
      'the unknown field is reported as a configuration problem'
    );
    Assert.isTrue(
      result.findingsWith(IdpResult.CODE_CONFIG_ISSUE)[0]
        .message.contains('No_Such_Field__c')
    );
    Assert.areEqual(1, result.fieldsApplied, 'the good rule still ran');
  }

  @IsTest
  static void currencyGuardIsInertWithoutARecordDenomination() {
    // In a single-currency org (and on records without CurrencyIsoCode)
    // the guard has nothing to compare against — a ZAR-typed amount still
    // writes. The clash path itself is unit-covered in IdpValueTypesTest.
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpValueTypes.Config zarMoney = new IdpValueTypes.Config();
    zarMoney.name = 'Money_ZAR';
    zarMoney.kind = IdpValueTypes.KIND_NUMBER;
    zarMoney.currencyCode = 'ZAR';

    Spec turnover = rule(
      'R1_Turnover',
      'Customer',
      'turnover',
      'Account',
      'AnnualRevenue'
    );
    turnover.rule.valueTypeName = 'Money_ZAR';
    install(
      new List<IdpConfigLoader.RawSection>{ section('Customer', 'Account') },
      new List<Spec>{ turnover },
      new Map<String, IdpValueTypes.Config>{ 'Money_ZAR' => zarMoney }
    );

    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"turnover": "R 1 234 567.00"}',
      null
    );
    Assert.isTrue(result.success, JSON.serialize(result.findings));
    Assert.areEqual(
      0,
      result.findingsWith(IdpResult.CODE_CURRENCY_MISMATCH).size()
    );
    Assert.areEqual(
      1234567,
      [SELECT AnnualRevenue FROM Account WHERE Id = :data.account.Id]
        .AnnualRevenue.intValue()
    );
  }

  @IsTest
  static void dmlFailuresAreAttributedToTheDocument() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    install(
      new List<IdpConfigLoader.RawSection>{ section('Case_Details', 'Case') },
      new List<Spec>{
        rule(
          'R1_Email',
          'Case_Details',
          'applicant.email',
          'Case',
          'SuppliedEmail'
        ),
        rule(
          'R2_Name',
          'Case_Details',
          'applicant.name',
          'Case',
          'SuppliedName'
        )
      },
      new Map<String, IdpValueTypes.Config>()
    );

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"applicant": {"email": "not an email at all", "name": "Jane"}}',
      null
    );
    Test.stopTest();

    Assert.isFalse(result.success, 'the save was rejected by validation');
    List<IdpResult.Finding> failures = result.findingsWith(
      IdpResult.CODE_DML_FAILED
    );
    Assert.isTrue(!failures.isEmpty(), JSON.serialize(result.findings));
    Assert.areEqual('Case', failures[0].objectName);
    Assert.areEqual(
      0,
      result.updatedRecordIds.size(),
      'partial-success DML: the record failed as a whole'
    );
  }

  @IsTest
  static void previewValueRejectsUnknownTypeNames() {
    try {
      IdpMappingController.previewValue('No_Such_Type_Xyz', 'R 100,00');
      Assert.fail('expected an AuraHandledException');
    } catch (AuraHandledException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  @IsTest
  static void previewValueParsesThroughAShippedType() {
    // "Money" ships with the package, so an admin can test it immediately.
    IdpMappingController.ValuePreview preview = IdpMappingController.previewValue(
      'Money',
      'R 1 234,56'
    );
    Assert.areEqual('Exact', preview.grade);
    Assert.isNull(preview.note, 'an Exact parse carries no note');
    Assert.areEqual('1234.56', preview.value);
    Assert.areEqual('1234.56', preview.rendered);
  }

  @IsTest
  static void loadsShippedSampleConfigFromCustomMetadata() {
    // The real query path, against the Estate_Intake records that ship in
    // this package — everything else injects DTOs.
    IdpConfigLoader.SetConfig config = IdpConfigLoader.load('Estate_Intake');
    Assert.isTrue(config.found);
    Assert.areEqual(2, config.sections.size(), 'Case + Account sections');
    Integer rules = 0;
    for (IdpConfigLoader.SectionConfig section : config.sections) {
      rules += section.rules.size();
    }
    Assert.areEqual(4, rules);
    Assert.areEqual(0, config.issues.size(), JSON.serialize(config.issues));
  }

  @IsTest
  static void shippedInvoiceSampleLoadsWithoutIssues() {
    // Asset carries three lookups to Account, so this sample would report
    // an ambiguous relationship the moment an Account anchored. Its keys
    // are unique across the org, so it declares rowScope: "None" instead.
    IdpConfigLoader.SetConfig config = IdpConfigLoader.load('Invoice_Intake');
    Assert.isTrue(config.found);
    Assert.areEqual(0, config.issues.size(), JSON.serialize(config.issues));
    Assert.areEqual(1, config.sections.size());
    Assert.isTrue(config.sections[0].repeating);
    Assert.areEqual('Asset', config.sections[0].targetObject);
  }

  @IsTest
  static void reportAndGuardPlumbing() {
    IdpResult.Result result = new IdpResult.Result();
    result.add(IdpResult.CODE_VALUE_MISMATCH, IdpResult.SEV_WARNING, 'differs');
    IdpResult.RunReport report = new IdpResult.RunReport();
    report.results.add(result);
    Assert.areEqual(
      1,
      report.allFindingsWith(IdpResult.CODE_VALUE_MISMATCH).size()
    );
    Assert.isFalse(result.compliant, 'a mismatch clears compliant');
    Assert.isTrue(result.success, 'a mismatch is not a failure');
    Assert.areEqual(0, result.errors().size());
    Assert.isTrue(IdpLimitsGuard.hasDmlHeadroom());
    Assert.isTrue(
      IdpResult.rank(IdpResult.Grade.EXACT) <
      IdpResult.rank(IdpResult.Grade.AMBIGUOUS)
    );
  }
}
