/**
 * Unit tests for previewing an unsaved mapping set definition.
 *
 * The Phase 5 gate: previewing a draft must agree with previewing the
 * saved set it was drafted from. That is the whole claim of previewDraft —
 * that the only difference between it and a real run is the definition
 * being substituted. If the two ever disagree on a definition that is
 * byte-identical to what is stored, the preview is lying about what a save
 * would do, which is worse than having no preview.
 */
@IsTest
private class IdpDraftPreviewTest {
  /**
   * Inserts the record a preview is seeded from.
   *
   * @return The inserted Account.
   */
  private static Account seedAccount() {
    Account account = new Account(Name = 'Preview Co');
    insert account;
    return account;
  }

  /**
   * Reads a shipped set's stored definition, as the loader holds it.
   *
   * @param setName DeveloperName of the mapping set.
   * @return Its Definition__c text, or null when the set is absent.
   */
  private static String storedDefinitionOf(String setName) {
    List<IDP_Mapping_Set__mdt> records = [
      SELECT Definition__c
      FROM IDP_Mapping_Set__mdt
      WHERE DeveloperName = :setName
      LIMIT 1
    ];
    return records.isEmpty() ? null : records[0].Definition__c;
  }

  /**
   * Reduces a result's findings to a sorted, comparable fingerprint.
   *
   * @param result Result to fingerprint.
   * @return Sorted code and severity pairs.
   */
  private static List<String> codesOf(IdpResult.Result result) {
    List<String> codes = new List<String>();
    for (IdpResult.Finding finding : result.findings) {
      codes.add(finding.code + '|' + finding.severity);
    }
    codes.sort();
    return codes;
  }

  /**
   * Verifies that every shipped set previews identically as a draft of its
   * own stored definition.
   */
  @IsTest
  static void aDraftOfTheStoredDefinitionPreviewsTheSame() {
    // A Long Text Area cannot be filtered in SOQL, so the ones without a
    // definition are dropped here rather than in the query.
    List<IDP_Mapping_Set__mdt> sets = new List<IDP_Mapping_Set__mdt>();
    for (IDP_Mapping_Set__mdt record : [
      SELECT DeveloperName, Definition__c
      FROM IDP_Mapping_Set__mdt
      ORDER BY DeveloperName
    ]) {
      if (String.isNotBlank(record.Definition__c)) {
        sets.add(record);
      }
    }
    if (sets.isEmpty()) {
      return; // an org with no mapping sets has nothing to compare
    }
    Account seed = seedAccount();
    String sample = '{"statement":{"periodEnd":"2026-08-31"}}';

    Test.startTest();
    for (IDP_Mapping_Set__mdt record : sets) {
      IdpMappingEngine.DocumentWork saved = new IdpMappingEngine.DocumentWork();
      saved.seedRecordId = seed.Id;
      saved.jsonString = sample;
      IdpResult.Result fromSaved = IdpMappingEngine.run(
        new List<IdpMappingEngine.DocumentWork>{ saved },
        record.DeveloperName,
        IdpMappingEngine.MODE_PREVIEW,
        null
      )[0];

      IdpResult.Result fromDraft = IdpMappingController.previewDraft(
        record.DeveloperName,
        record.Definition__c,
        sample,
        seed.Id
      );

      Assert.areEqual(
        codesOf(fromSaved),
        codesOf(fromDraft),
        record.DeveloperName +
        ' previews differently as a draft than as the set it came from'
      );
    }
    Test.stopTest();
  }

  /**
   * Verifies that previewing an edited draft leaves the stored definition
   * untouched.
   */
  @IsTest
  static void anEditedDraftPreviewsWithoutTouchingWhatIsStored() {
    String stored = storedDefinitionOf('Estate_Intake');
    if (stored == null) {
      return;
    }
    Account seed = seedAccount();

    // A definition the set does not have: one section, one rule.
    String draft =
      '{"sections":[{"name":"Draft_Case","label":"Draft: Case",' +
      '"sectionType":"Fixed","targetObject":"Account","rules":[' +
      '{"name":"Draft_Name","jsonPath":"applicant.name",' +
      '"targetField":"Name","overwritePolicy":"Always"}]}]}';

    Test.startTest();
    IdpResult.Result result = IdpMappingController.previewDraft(
      'Estate_Intake',
      draft,
      '{"applicant":{"name":"A Ndlovu"}}',
      seed.Id
    );
    Test.stopTest();

    Assert.isNotNull(result, 'a draft previews');
    Assert.areEqual(
      stored,
      storedDefinitionOf('Estate_Intake'),
      'previewing a draft must not write anything back'
    );
  }

  /**
   * Verifies that a draft under a name no mapping set holds previews
   * without raising an error, so a document type can be built from
   * nothing.
   */
  @IsTest
  static void aDraftForASetThatDoesNotExistStillPreviews() {
    // A document type can be drafted before the record exists, which is
    // how a new one gets built at all.
    Account seed = seedAccount();
    String draft =
      '{"sections":[{"name":"New_Account","label":"New: Account",' +
      '"sectionType":"Fixed","targetObject":"Account","rules":[' +
      '{"name":"New_Name","jsonPath":"name","targetField":"Name",' +
      '"overwritePolicy":"Always"}]}]}';

    Test.startTest();
    IdpResult.Result result = IdpMappingController.previewDraft(
      'No_Such_Set_Anywhere',
      draft,
      '{"name":"A Ndlovu"}',
      seed.Id
    );
    Test.stopTest();

    Assert.isNotNull(result);
    for (IdpResult.Finding finding : result.findings) {
      Assert.areNotEqual(
        IdpResult.SEV_ERROR,
        finding.severity,
        'a draft for an unknown set is not an error: ' + finding.message
      );
    }
  }

  /**
   * Verifies that unreadable draft JSON becomes a finding on the result
   * rather than an exception at the editor.
   */
  @IsTest
  static void aDraftThatWillNotLoadReportsRatherThanThrows() {
    Account seed = seedAccount();

    Test.startTest();
    IdpResult.Result result = IdpMappingController.previewDraft(
      'Estate_Intake',
      '{"sections": [ ,, ]',
      '{}',
      seed.Id
    );
    Test.stopTest();

    Boolean sawError = false;
    for (IdpResult.Finding finding : result.findings) {
      sawError |= finding.severity == IdpResult.SEV_ERROR;
    }
    Assert.isTrue(
      sawError,
      'unreadable JSON is reported on the result, not raised at the editor'
    );
  }

  /**
   * Verifies that a preview plans a field change without writing it.
   */
  @IsTest
  static void previewSkipsTheDmlAndSaysSo() {
    Account seed = seedAccount();
    String before = [SELECT Name FROM Account WHERE Id = :seed.Id].Name;
    String draft =
      '{"sections":[{"name":"P_Account","label":"P: Account",' +
      '"sectionType":"Fixed","targetObject":"Account","rules":[' +
      '{"name":"P_Name","jsonPath":"name","targetField":"Name",' +
      '"overwritePolicy":"Always"}]}]}';

    Test.startTest();
    IdpMappingController.previewDraft(
      'P_Set',
      draft,
      '{"name":"Renamed By Preview"}',
      seed.Id
    );
    Test.stopTest();

    Assert.areEqual(
      before,
      [SELECT Name FROM Account WHERE Id = :seed.Id].Name,
      'a preview plans the change; it does not make it'
    );
  }
}
