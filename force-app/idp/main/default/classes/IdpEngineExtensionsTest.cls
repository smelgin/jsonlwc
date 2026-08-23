/**
 * Tests for the ENG-1/2/3/4/9 engine extensions: per-rule Custom handlers,
 * opt-in creation of unmatched rows and missing anchors, the Queueable
 * async path, and the weighted document confidence score. Config is
 * injected the same way IdpMappingEngineTest does it — Raw* DTOs through
 * the real loader validation, priming the loader cache.
 */
@IsTest
private class IdpEngineExtensionsTest {
  private static final String SET_NAME = 'Engine_Extensions_Set';

  /** ENG-1: writes an audit trail onto the record it was handed. */
  public class StampingFieldHandler implements IIdpFieldHandler {
    public void handle(IdpFieldContext context) {
      context.record.put(
        'Description',
        'HANDLED ' +
          context.targetObject +
          '.' +
          context.targetField +
          ' = ' +
          String.valueOf(context.parsedValue) +
          ' [' +
          context.grade +
          ']'
      );
    }
  }

  /** ENG-1: a handler whose failure must become a finding, not a crash. */
  public class ThrowingFieldHandler implements IIdpFieldHandler {
    public void handle(IdpFieldContext context) {
      throw new IllegalArgumentException('deliberate handler failure');
    }
  }

  /** Not an IIdpFieldHandler — config validation must catch it. */
  public class NotAFieldHandler {
  }

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

  // ─────────────────────────── ENG-1 ──────────────────────────────

  private static IdpConfigLoader.RawSection customRuleSection() {
    IdpConfigLoader.RawSection details = section('Case_Details', 'Case');
    IdpConfigLoader.RawRule normal = rule(
      'R_Name',
      'applicant.name',
      'SuppliedName'
    );
    IdpConfigLoader.RawRule custom = rule(
      'R_Custom',
      'applicant.name',
      'Description'
    );
    custom.mode = 'Custom';
    custom.handlerClass = 'IdpEngineExtensionsTest.StampingFieldHandler';
    details.rules.add(normal);
    details.rules.add(custom);
    return details;
  }

  @IsTest
  static void customRuleHandlerMutatesAndEngineFlushes() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    install(new List<IdpConfigLoader.RawSection>{ customRuleSection() });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"applicant":{"name":"Thandi Nkosi"}}',
      'Extraction'
    );
    Test.stopTest();

    Assert.isTrue(result.success, JSON.serialize(result.findings));
    Case updated = [
      SELECT SuppliedName, Description
      FROM Case
      WHERE Id = :data.caseRecord.Id
    ];
    Assert.areEqual('Thandi Nkosi', updated.SuppliedName);
    Assert.areEqual(
      'HANDLED Case.Description = Thandi Nkosi [Exact]',
      updated.Description,
      'the handler\'s in-memory mutation joined the run\'s single update'
    );
    Assert.isTrue(
      result.updatedRecordIds.contains(String.valueOf(data.caseRecord.Id))
    );
  }

  @IsTest
  static void customRuleIsSkippedInPreviewAndSaysSo() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    install(new List<IdpConfigLoader.RawSection>{ customRuleSection() });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"applicant":{"name":"Thandi Nkosi"}}',
      'Preview'
    );
    Test.stopTest();

    Assert.isTrue(
      hasFinding(result, IdpResult.CODE_HANDLER_SKIPPED),
      'preview must say the plan is incomplete: ' +
      JSON.serialize(result.findings)
    );
    Assert.isNull(
      [SELECT Description FROM Case WHERE Id = :data.caseRecord.Id].Description,
      'preview writes nothing'
    );
    for (IdpResult.PlannedChange change : result.plannedChanges) {
      Assert.areNotEqual(
        'Description',
        change.fieldName,
        'the skipped handler\'s writes are absent from the plan'
      );
    }
  }

  @IsTest
  static void failingHandlerBecomesAFindingAndTheRunContinues() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpConfigLoader.RawSection details = section('Case_Details', 'Case');
    IdpConfigLoader.RawRule normal = rule(
      'R_Name',
      'applicant.name',
      'SuppliedName'
    );
    IdpConfigLoader.RawRule custom = rule(
      'R_Custom',
      'applicant.name',
      'Description'
    );
    custom.mode = 'Custom';
    custom.handlerClass = 'IdpEngineExtensionsTest.ThrowingFieldHandler';
    details.rules.add(custom);
    details.rules.add(normal);
    install(new List<IdpConfigLoader.RawSection>{ details });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"applicant":{"name":"Thandi Nkosi"}}',
      'Extraction'
    );
    Test.stopTest();

    List<IdpResult.Finding> failures = result.findingsWith(
      IdpResult.CODE_HANDLER_FAILED
    );
    Assert.areEqual(1, failures.size(), JSON.serialize(result.findings));
    Assert.isTrue(failures[0].message.contains('deliberate handler failure'));
    Assert.areEqual(
      'Thandi Nkosi',
      [SELECT SuppliedName FROM Case WHERE Id = :data.caseRecord.Id]
      .SuppliedName,
      'the ordinary rule still applied'
    );
  }

  @IsTest
  static void customRuleConfigProblemsAreLoadTimeIssues() {
    IdpConfigLoader.RawSection missing = section('S1', 'Case');
    IdpConfigLoader.RawRule noHandler = rule('R_NoHandler', 'a', 'Subject');
    noHandler.mode = 'Custom';
    missing.rules.add(noHandler);
    IdpConfigLoader.RawRule wrongType = rule('R_WrongType', 'a', 'Subject');
    wrongType.mode = 'Custom';
    wrongType.handlerClass = 'IdpEngineExtensionsTest.NotAFieldHandler';
    missing.rules.add(wrongType);
    IdpConfigLoader.RawRule strayHandler = rule('R_Stray', 'a', 'Subject');
    strayHandler.handlerClass = 'IdpEngineExtensionsTest.StampingFieldHandler';
    missing.rules.add(strayHandler);

    IdpConfigLoader.SetConfig config = install(
      new List<IdpConfigLoader.RawSection>{ missing }
    );

    String issues = JSON.serialize(config.issues);
    Assert.isTrue(
      issues.contains('no handlerClass'),
      'Custom without a handler is reported: ' + issues
    );
    Assert.isTrue(
      issues.contains('does not implement IIdpFieldHandler'),
      'a wrong-typed handler is reported: ' + issues
    );
    Assert.isTrue(
      issues.contains('Mode is not Custom'),
      'a stray handlerClass is reported: ' + issues
    );
    Assert.areEqual(
      1,
      config.sections[0].rules.size(),
      'the two broken Custom rules were skipped, the stray-handler rule kept'
    );
  }

  // ─────────────────────────── ENG-2 ──────────────────────────────

  /** Anchors the Account (a parent hop from the Case root), so created
   *  rows have a parent to hang off. */
  private static IdpConfigLoader.RawSection customerSection() {
    IdpConfigLoader.RawSection customer = section('Customer', 'Account');
    customer.rules.add(rule('C1_Invoice', 'Invoice', 'Description'));
    return customer;
  }

  private static IdpConfigLoader.RawSection invoiceLines(String unmatchedRows) {
    IdpConfigLoader.RawSection lines = new IdpConfigLoader.RawSection();
    lines.name = 'Lines';
    lines.label = 'Lines';
    lines.sectionType = 'Repeating';
    lines.targetObject = 'Asset';
    lines.rowPath = 'Details';
    lines.matchField = 'SerialNumber';
    lines.matchValue = 'INV-{json:Invoice}-{row:number}';
    lines.parentSection = 'Customer';
    lines.unmatchedRows = unmatchedRows;
    lines.rules.add(rule('L1_Quantity', 'Quantity', 'Quantity'));
    lines.rules.add(rule('L2_Name', 'Description', 'Name'));
    return lines;
  }

  private static String invoiceJson() {
    return JSON.serialize(
      new Map<String, Object>{
        'Invoice' => 'A1',
        'Details' => new List<Object>{
          new Map<String, Object>{
            'Quantity' => 3,
            'Description' => 'Widgets'
          },
          new Map<String, Object>{
            'Quantity' => 5,
            'Description' => 'Sprockets'
          }
        }
      }
    );
  }

  @IsTest
  static void unmatchedRowsCreateInsertsTheMissingRow() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    insert new Asset(
      Name = 'Line one',
      AccountId = data.account.Id,
      SerialNumber = 'INV-A1-1'
    );
    install(
      new List<IdpConfigLoader.RawSection>{
        customerSection(),
        invoiceLines('Create')
      }
    );

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      invoiceJson(),
      'Extraction'
    );
    Test.stopTest();

    Assert.areEqual(1, result.rowsMatched, JSON.serialize(result.findings));
    Assert.areEqual(1, result.rowsCreated);
    Assert.areEqual(1, result.createdRecordIds.size());
    Assert.isTrue(hasFinding(result, IdpResult.CODE_ROW_CREATED));
    Assert.isTrue(
      result.unmatchedRowKeys.isEmpty(),
      'a created row is no longer unmatched'
    );
    List<Asset> created = [
      SELECT Name, AccountId, Quantity
      FROM Asset
      WHERE SerialNumber = 'INV-A1-2'
    ];
    Assert.areEqual(1, created.size());
    Assert.areEqual('Sprockets', created[0].Name);
    Assert.areEqual(
      data.account.Id,
      created[0].AccountId,
      'the created row hangs off the resolved parent'
    );
    Assert.areEqual(5, created[0].Quantity.intValue());
  }

  @IsTest
  static void previewPlansCreationsWithoutInserting() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    install(
      new List<IdpConfigLoader.RawSection>{
        customerSection(),
        invoiceLines('Create')
      }
    );

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      invoiceJson(),
      'Preview'
    );
    Test.stopTest();

    Assert.areEqual(
      2,
      result.findingsWith(IdpResult.CODE_ROW_CREATED).size(),
      'both rows are planned creations: ' + JSON.serialize(result.findings)
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Asset], 'preview inserts nothing');
    Boolean sawNewChange = false;
    for (IdpResult.PlannedChange change : result.plannedChanges) {
      if (change.isNew == true) {
        sawNewChange = true;
        Assert.isNull(change.recordId, 'a planned creation has no Id yet');
      }
    }
    Assert.isTrue(sawNewChange, JSON.serialize(result.plannedChanges));
  }

  @IsTest
  static void complianceNeverCreates() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    install(
      new List<IdpConfigLoader.RawSection>{
        customerSection(),
        invoiceLines('Create')
      }
    );

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      invoiceJson(),
      'Compliance'
    );
    Test.stopTest();

    Assert.areEqual(0, [SELECT COUNT() FROM Asset]);
    Assert.areEqual(0, result.rowsCreated);
    Assert.isTrue(
      hasFinding(result, IdpResult.CODE_ROW_UNMATCHED),
      JSON.serialize(result.findings)
    );
  }

  @IsTest
  static void creationPoliciesOnTheWrongSectionTypeAreIgnored() {
    IdpConfigLoader.RawSection fixedWithRows = section('S1', 'Case');
    fixedWithRows.unmatchedRows = 'Create';
    fixedWithRows.rules.add(rule('R1', 'a', 'Subject'));
    IdpConfigLoader.RawSection badValue = invoiceLines('Upsert');

    IdpConfigLoader.SetConfig config = install(
      new List<IdpConfigLoader.RawSection>{ fixedWithRows, badValue }
    );

    String issues = JSON.serialize(config.issues);
    Assert.isTrue(
      issues.contains('does not apply to this section type'),
      issues
    );
    // NB: issues is serialized JSON, so quotes inside messages are escaped.
    Assert.isTrue(issues.contains('unknown unmatchedRows value'), issues);
    Assert.isNull(config.sections[0].unmatchedRowPolicy);
    Assert.isNull(config.sections[1].unmatchedRowPolicy);
  }

  // ─────────────────────────── ENG-3 ──────────────────────────────

  @IsTest
  static void whenNoAnchorCreatesTheMissingAnchor() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    // The Account section anchors the parent the created Asset links to.
    IdpConfigLoader.RawSection customer = section('Customer', 'Account');
    customer.rules.add(rule('C1_Name', 'holding.name', 'Description'));
    IdpConfigLoader.RawSection holding = section('Holding', 'Asset');
    holding.whenNoAnchor = 'Create';
    holding.rules.add(rule('H1_Name', 'holding.name', 'Name'));
    holding.rules.add(rule('H2_Serial', 'holding.serial', 'SerialNumber'));
    install(new List<IdpConfigLoader.RawSection>{ customer, holding });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"holding":{"name":"Money market fund","serial":"MM-1"}}',
      'Extraction'
    );
    Test.stopTest();

    Assert.isTrue(
      hasFinding(result, IdpResult.CODE_ANCHOR_CREATED),
      JSON.serialize(result.findings)
    );
    Assert.isFalse(hasFinding(result, IdpResult.CODE_UNREACHABLE_TARGET));
    Assert.areEqual(1, result.createdRecordIds.size());
    List<Asset> created = [
      SELECT Name, AccountId
      FROM Asset
      WHERE SerialNumber = 'MM-1'
    ];
    Assert.areEqual(1, created.size());
    Assert.areEqual('Money market fund', created[0].Name);
    Assert.areEqual(
      data.account.Id,
      created[0].AccountId,
      'the created anchor links to the first resolved record it looks up to'
    );
  }

  @IsTest
  static void withoutThePolicyAMissingAnchorStaysAnError() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpConfigLoader.RawSection holding = section('Holding', 'Asset');
    holding.rules.add(rule('H1_Name', 'holding.name', 'Name'));
    install(new List<IdpConfigLoader.RawSection>{ holding });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"holding":{"name":"Money market fund"}}',
      'Extraction'
    );
    Test.stopTest();

    Assert.isTrue(hasFinding(result, IdpResult.CODE_UNREACHABLE_TARGET));
    Assert.areEqual(0, [SELECT COUNT() FROM Asset]);
  }

  // ─────────────────────────── ENG-4 ──────────────────────────────

  @IsTest
  static void asyncProcessorRunsTheEngineOnAFreshTransaction() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpConfigLoader.RawSection details = section('Case_Details', 'Case');
    details.rules.add(rule('R_Name', 'applicant.name', 'SuppliedName'));
    install(new List<IdpConfigLoader.RawSection>{ details });

    IdpAsyncProcessor.DocumentInput document = new IdpAsyncProcessor.DocumentInput();
    document.contentDocumentId = data.contentDocumentId;
    document.jsonString = '{"applicant":{"name":"Thandi Nkosi"}}';

    Test.startTest();
    Id jobId = IdpAsyncProcessor.enqueue(
      new List<IdpAsyncProcessor.DocumentInput>{ document },
      SET_NAME,
      'Extraction',
      null
    );
    Test.stopTest();

    Assert.isNotNull(jobId);
    Assert.areEqual(
      'Thandi Nkosi',
      [SELECT SuppliedName FROM Case WHERE Id = :data.caseRecord.Id]
      .SuppliedName,
      'the queueable ran the engine'
    );
  }

  // ─────────────────────────── ENG-9 ──────────────────────────────

  @IsTest
  static void documentConfidenceIsAWeightedAverage() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpConfigLoader.RawSection details = section('Case_Details', 'Case');
    IdpConfigLoader.RawRule name = rule('R_Name', 'name', 'SuppliedName');
    name.confidenceWeight = 3;
    IdpConfigLoader.RawRule phone = rule('R_Phone', 'phone', 'SuppliedPhone');
    phone.confidenceWeight = 1;
    IdpConfigLoader.RawRule notes = rule('R_Notes', 'notes', 'Description');
    // no weight — its envelope must not count
    IdpConfigLoader.RawRule email = rule('R_Email', 'email', 'SuppliedEmail');
    email.confidenceWeight = 5; // weighted, but the document has no envelope
    details.rules.add(name);
    details.rules.add(phone);
    details.rules.add(notes);
    details.rules.add(email);
    install(new List<IdpConfigLoader.RawSection>{ details });

    Test.startTest();
    IdpResult.Result result = runOne(
      data.contentDocumentId,
      JSON.serialize(
        new Map<String, Object>{
          'name' => new Map<String, Object>{
            'value' => 'Thandi Nkosi',
            'confidence' => 0.9
          },
          // 93 on the percent scale must read as 0.93
          'phone' => new Map<String, Object>{
            'value' => '0821234567',
            'confidence' => 93
          },
          'notes' => new Map<String, Object>{
            'value' => 'unweighted',
            'confidence' => 0.1
          },
          'email' => 'thandi@example.com'
        }
      ),
      'Extraction'
    );
    Test.stopTest();

    // (3 × 0.9 + 1 × 0.93) / (3 + 1); the unweighted and unannotated
    // fields are excluded from both sums.
    Assert.areEqual(
      0.9075,
      result.documentConfidence,
      JSON.serialize(result.findings)
    );
  }

  @IsTest
  static void documentConfidenceIsNullWithoutSamples() {
    IdpTestData.CaseWithFile data = IdpTestData.caseWithFile();
    IdpConfigLoader.RawSection details = section('Case_Details', 'Case');
    IdpConfigLoader.RawRule name = rule('R_Name', 'name', 'SuppliedName');
    name.confidenceWeight = 3;
    details.rules.add(name);
    install(new List<IdpConfigLoader.RawSection>{ details });

    IdpResult.Result result = runOne(
      data.contentDocumentId,
      '{"name":"Thandi Nkosi"}',
      'Extraction'
    );

    Assert.isNull(
      result.documentConfidence,
      '"no score" must be distinguishable from "zero"'
    );
    Assert.areEqual(
      'Thandi Nkosi',
      [SELECT SuppliedName FROM Case WHERE Id = :data.caseRecord.Id]
      .SuppliedName
    );
  }

  @IsTest
  static void negativeConfidenceWeightIsIgnoredWithAWarning() {
    IdpConfigLoader.RawSection details = section('S1', 'Case');
    IdpConfigLoader.RawRule bad = rule('R1', 'a', 'Subject');
    bad.confidenceWeight = -2;
    details.rules.add(bad);

    IdpConfigLoader.SetConfig config = install(
      new List<IdpConfigLoader.RawSection>{ details }
    );

    Assert.isTrue(
      JSON.serialize(config.issues).contains('negative confidenceWeight')
    );
    Assert.isNull(config.sections[0].rules[0].confidenceWeight);
  }
}
