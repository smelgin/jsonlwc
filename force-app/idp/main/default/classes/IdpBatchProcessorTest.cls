/**
 * Batch tests. The JSON source field is Case.Description here purely so
 * the test runs in any org — a real org points JSON_Source_Field__c at
 * its hub object's long-text field (e.g. Document__c.Extracted_JSON__c).
 */
@IsTest
private class IdpBatchProcessorTest {
  private static final String SET_NAME = 'Batch_Test_Set';

  private static void install(String jsonSourceField) {
    install(jsonSourceField, null, 'Case', 'SuppliedName');
  }

  /** The marker tests run against Contact (Description as stored JSON,
   *  EmailBouncedDate as the Datetime marker) because Case carries no
   *  universally-updateable standard Datetime field. */
  private static void installContactSet(String markerField) {
    install('Contact.Description', markerField, 'Contact', 'LastName');
  }

  private static void install(
    String jsonSourceField,
    String markerField,
    String targetObject,
    String targetField
  ) {
    IdpConfigLoader.RawSet rawSet = new IdpConfigLoader.RawSet();
    rawSet.name = SET_NAME;
    rawSet.label = SET_NAME;
    rawSet.jsonSourceField = jsonSourceField;
    rawSet.processedMarkerField = markerField;

    IdpConfigLoader.RawSection detail = new IdpConfigLoader.RawSection();
    detail.name = 'Details';
    detail.label = 'Details';
    detail.sectionType = 'Fixed';
    detail.targetObject = targetObject;

    IdpConfigLoader.RawRule nameRule = new IdpConfigLoader.RawRule();
    nameRule.name = 'B1_Name';
    nameRule.label = 'Name';
    nameRule.sectionName = 'Details';
    nameRule.jsonPath = 'applicant.name';
    nameRule.targetObject = targetObject;
    nameRule.targetField = targetField;
    nameRule.overwritePolicy = 'Always';

    IdpConfigLoader.cache.put(
      SET_NAME,
      IdpConfigLoader.assemble(
        rawSet,
        new List<IdpConfigLoader.RawSection>{ detail },
        new List<IdpConfigLoader.RawRule>{ nameRule },
        new Map<String, IdpValueTypes.Config>()
      )
    );
  }

  @IsTest
  static void processesStoredJsonFromTheConfiguredField() {
    List<Case> cases = new List<Case>();
    for (Integer i = 0; i < 3; i++) {
      cases.add(
        new Case(
          Subject = 'Doc ' + i,
          Description = '{"applicant": {"name": "Person ' + i + '"}}'
        )
      );
    }
    insert cases;
    install('Case.Description');

    Test.startTest();
    Database.executeBatch(new IdpBatchProcessor(SET_NAME), 10);
    Test.stopTest();

    Map<Id, Case> updated = new Map<Id, Case>(
      [SELECT SuppliedName FROM Case WHERE Id IN :cases]
    );
    for (Integer i = 0; i < cases.size(); i++) {
      Assert.areEqual(
        'Person ' + i,
        updated.get(cases[i].Id).SuppliedName,
        'each record was seeded from its own stored JSON'
      );
    }
  }

  @IsTest
  static void acceptsAScopeQueryOverride() {
    insert new Case(
      Subject = 'In scope',
      Description = '{"applicant": {"name": "Only Me"}}'
    );
    insert new Case(
      Subject = 'Out of scope',
      Description = '{"applicant": {"name": "Not Me"}}'
    );
    install('Case.Description');

    Test.startTest();
    Database.executeBatch(
      new IdpBatchProcessor(
        SET_NAME,
        null,
        null,
        'SELECT Id, Description FROM Case WHERE Subject = \'In scope\''
      ),
      10
    );
    Test.stopTest();

    Assert.areEqual(
      'Only Me',
      [SELECT SuppliedName FROM Case WHERE Subject = 'In scope'].SuppliedName
    );
    Assert.isNull(
      [SELECT SuppliedName FROM Case WHERE Subject = 'Out of scope']
      .SuppliedName
    );
  }

  /** Runs one batch pass synchronously via direct start()/execute(), so a
   *  test can sequence several passes and assert between them. */
  private static Integer runPass(IdpBatchProcessor batch) {
    List<SObject> scope = Database.query(batch.start(null).getQuery());
    if (!scope.isEmpty()) {
      batch.execute(null, scope);
    }
    return scope.size();
  }

  @IsTest
  static void markerMakesRerunsIdempotent() {
    List<Contact> contacts = new List<Contact>();
    for (Integer i = 0; i < 2; i++) {
      contacts.add(
        new Contact(
          LastName = 'Pending' + i,
          Description = '{"applicant": {"name": "Person' + i + '"}}'
        )
      );
    }
    insert contacts;
    installContactSet('EmailBouncedDate');

    Test.startTest();
    Integer firstPass = runPass(new IdpBatchProcessor(SET_NAME));

    // Simulate new upstream data arriving AFTER processing. Only the
    // Description is written, so the engine's own writes stay intact.
    List<Contact> newJson = new List<Contact>();
    for (Contact processed : contacts) {
      newJson.add(
        new Contact(
          Id = processed.Id,
          Description = '{"applicant": {"name": "Changed"}}'
        )
      );
    }
    update newJson;

    Integer secondPass = runPass(new IdpBatchProcessor(SET_NAME));
    Test.stopTest();

    Assert.areEqual(2, firstPass);
    Assert.areEqual(
      0,
      secondPass,
      'stamped records must not be picked up again'
    );
    for (Contact processed : [
      SELECT LastName, EmailBouncedDate
      FROM Contact
      WHERE Id IN :contacts
    ]) {
      Assert.isNotNull(
        processed.EmailBouncedDate,
        'processed records are stamped'
      );
      Assert.isTrue(
        processed.LastName.startsWith('Person'),
        'the rerun must not have applied the changed JSON: ' +
        processed.LastName
      );
    }
  }

  @IsTest
  static void reprocessAllIgnoresTheMarker() {
    insert new Contact(
      LastName = 'Pending',
      Description = '{"applicant": {"name": "Original"}}'
    );
    installContactSet('EmailBouncedDate');

    Test.startTest();
    runPass(new IdpBatchProcessor(SET_NAME));
    Contact processed = [SELECT Id FROM Contact LIMIT 1];
    processed.Description = '{"applicant": {"name": "Corrected"}}';
    update processed;
    Integer rerun = runPass(
      new IdpBatchProcessor(SET_NAME, null, null, null, true)
    );
    Test.stopTest();

    Assert.areEqual(1, rerun, 'reprocessAll picks stamped records up again');
    Assert.areEqual(
      'Corrected',
      [SELECT LastName FROM Contact LIMIT 1].LastName
    );
  }

  @IsTest
  static void deferredDocumentsStayUnstampedForRetry() {
    insert new Contact(
      LastName = 'Pending',
      Description = '{"applicant": {"name": "Person"}}'
    );
    installContactSet('EmailBouncedDate');

    Test.startTest();
    IdpLimitsGuard.testQueryHeadroom = 1; // starve the engine
    runPass(new IdpBatchProcessor(SET_NAME));
    IdpLimitsGuard.testQueryHeadroom = null;
    Integer retryPass = runPass(new IdpBatchProcessor(SET_NAME));
    Test.stopTest();

    Contact processed = [
      SELECT LastName, EmailBouncedDate
      FROM Contact
      LIMIT 1
    ];
    Assert.areEqual(
      'Person',
      processed.LastName,
      'the retry pass found the unstamped record and finished the job'
    );
    Assert.isNotNull(processed.EmailBouncedDate);
    Assert.areEqual(1, retryPass, 'exactly the deferred record was retried');
  }

  @IsTest
  static void refusesANonDatetimeMarkerField() {
    installContactSet('LastName'); // text, not Datetime
    try {
      new IdpBatchProcessor(SET_NAME).start(null);
      Assert.fail('expected a BatchException');
    } catch (IdpBatchProcessor.BatchException e) {
      Assert.isTrue(e.getMessage().contains('Datetime'));
    }
  }

  @IsTest
  static void refusesToStartWithoutAJsonSourceField() {
    install(null);
    try {
      new IdpBatchProcessor(SET_NAME).start(null);
      Assert.fail('expected a BatchException');
    } catch (IdpBatchProcessor.BatchException e) {
      Assert.isTrue(e.getMessage().contains('JSON Source Field'));
    }

    install('Case.No_Such_Field__c');
    try {
      new IdpBatchProcessor(SET_NAME).start(null);
      Assert.fail('expected a BatchException');
    } catch (IdpBatchProcessor.BatchException e) {
      Assert.isTrue(e.getMessage().contains('No_Such_Field__c'));
    }
  }
}
