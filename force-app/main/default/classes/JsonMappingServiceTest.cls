@IsTest
private class JsonMappingServiceTest {
  private static JSON_Field_Mapping__mdt makeRule(
    String path,
    String targetObject,
    String targetField,
    String policy,
    String transform
  ) {
    return makeRule(path, targetObject, targetField, policy, transform, null);
  }

  private static JSON_Field_Mapping__mdt makeRule(
    String path,
    String targetObject,
    String targetField,
    String policy,
    String transform,
    String mode
  ) {
    return new JSON_Field_Mapping__mdt(
      JSON_Path__c = path,
      Target_Object__c = targetObject,
      Target_Field__c = targetField,
      Overwrite_Policy__c = policy,
      Transform__c = transform,
      Mode__c = mode
    );
  }

  /** Account + Case + a file linked to the Case. */
  private static Id setupCaseWithFile() {
    Account account = new Account(
      Name = 'Estate Holder',
      Phone = '555-EXISTING'
    );
    insert account;
    Case caseRecord = new Case(
      AccountId = account.Id,
      Subject = 'Estate intake'
    );
    insert caseRecord;
    ContentVersion cv = new ContentVersion(
      Title = 'Scanned form',
      PathOnClient = 'form.pdf',
      VersionData = Blob.valueOf('pdf bytes')
    );
    insert cv;
    Id contentDocumentId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      ContentDocumentId = contentDocumentId,
      LinkedEntityId = caseRecord.Id,
      ShareType = 'V'
    );
    return contentDocumentId;
  }

  @IsTest
  static void appliesMappingsToReachableRecords() {
    Id contentDocumentId = setupCaseWithFile();
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      makeRule('applicant.name', 'Case', 'SuppliedName', 'Always', null),
      makeRule('estate.description', 'Case', 'Description', 'Always', null),
      // Account.Phone is prefilled → Only if blank must skip it.
      makeRule('applicant.phone', 'Account', 'Phone', 'Only if blank', null),
      // Path absent from the JSON → silently skipped.
      makeRule('applicant.missing', 'Case', 'SuppliedEmail', 'Always', null)
    };
    String jsonString = JSON.serialize(
      new Map<String, Object>{
        'applicant' => new Map<String, Object>{
          'name' => 'Jane Doe',
          'phone' => '555-NEW'
        },
        'estate' => new Map<String, Object>{
          'description' => 'Captured from scanned form'
        }
      }
    );

    Test.startTest();
    JsonMappingService.Result result = JsonMappingService.applyMappings(
      contentDocumentId,
      jsonString,
      'Estate_Intake',
      null,
      null
    );
    Test.stopTest();

    Assert.isTrue(result.success, 'Expected success, errors: ' + result.errors);
    Assert.isTrue(result.compliant, 'Extraction run has no mismatches');
    Assert.areEqual(2, result.fieldsApplied, 'Two fields should map');
    Assert.areEqual(
      1,
      result.updatedRecordIds.size(),
      'Only the Case should be updated'
    );
    Case updated = [
      SELECT SuppliedName, Description
      FROM Case
      WHERE Id = :result.updatedRecordIds[0]
    ];
    Assert.areEqual('Jane Doe', updated.SuppliedName);
    Assert.areEqual('Captured from scanned form', updated.Description);
    Assert.areEqual(
      '555-EXISTING',
      [SELECT Phone FROM Account LIMIT 1].Phone,
      'Only-if-blank must not overwrite the existing phone'
    );
  }

  @IsTest
  static void overwritesBlankFieldWithOnlyIfBlankPolicy() {
    Id contentDocumentId = setupCaseWithFile();
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      makeRule('applicant.name', 'Case', 'SuppliedName', 'Only if blank', null)
    };

    JsonMappingService.Result result = JsonMappingService.applyMappings(
      contentDocumentId,
      '{"applicant":{"name":"Jane Doe"}}',
      'Estate_Intake',
      null,
      null
    );

    Assert.isTrue(result.success, 'Errors: ' + result.errors);
    Assert.areEqual(
      'Jane Doe',
      [SELECT SuppliedName FROM Case LIMIT 1].SuppliedName,
      'Blank field should be filled'
    );
  }

  @IsTest
  static void complianceReportsMismatchesWithoutDml() {
    Id contentDocumentId = setupCaseWithFile();
    // Stored name differs only in case/whitespace → normalized match.
    Case caseRecord = [SELECT Id FROM Case LIMIT 1];
    caseRecord.SuppliedName = '  JANE   DOE ';
    update caseRecord;
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      makeRule('applicant.name', 'Case', 'SuppliedName', 'Always', null),
      // Stored phone differs → mismatch.
      makeRule('applicant.phone', 'Account', 'Phone', 'Always', null),
      // Stored description is blank → mismatch by design.
      makeRule('estate.description', 'Case', 'Description', 'Always', null)
    };
    String jsonString =
      '{"applicant":{"name":"Jane Doe","phone":"555-NEW"},' +
      '"estate":{"description":"From the form"}}';

    Test.startTest();
    JsonMappingService.Result result = JsonMappingService.applyMappings(
      contentDocumentId,
      jsonString,
      'Estate_Intake',
      'Compliance',
      null
    );
    Test.stopTest();

    Assert.isTrue(result.success, 'Errors: ' + result.errors);
    Assert.isFalse(result.compliant, 'Two fields differ');
    Assert.areEqual(3, result.fieldsCompared);
    Assert.areEqual(2, result.mismatches.size());
    Assert.areEqual(0, result.fieldsApplied, 'Compliance must not write');
    Assert.areEqual(0, result.updatedRecordIds.size());
    Assert.isNull(
      [SELECT Description FROM Case LIMIT 1].Description,
      'Compliance must not modify records'
    );
    JsonMappingService.Mismatch phoneMismatch;
    for (JsonMappingService.Mismatch m : result.mismatches) {
      if (m.fieldName == 'Phone') {
        phoneMismatch = m;
      }
    }
    Assert.isNotNull(phoneMismatch, 'Phone mismatch expected');
    Assert.areEqual('Account', phoneMismatch.objectName);
    Assert.areEqual('555-NEW', phoneMismatch.extractedValue);
    Assert.areEqual('555-EXISTING', phoneMismatch.actualValue);
    Assert.areEqual('applicant.phone', phoneMismatch.jsonPath);
  }

  @IsTest
  static void perRuleModeOverridesRunMode() {
    Id contentDocumentId = setupCaseWithFile();
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      // Run mode (default Extraction) applies here.
      makeRule('applicant.name', 'Case', 'SuppliedName', 'Always', null),
      // Per-rule override: verify instead of write.
      makeRule(
        'applicant.phone',
        'Account',
        'Phone',
        'Always',
        null,
        'Compliance'
      )
    };

    JsonMappingService.Result result = JsonMappingService.applyMappings(
      contentDocumentId,
      '{"applicant":{"name":"Jane Doe","phone":"555-NEW"}}',
      'Estate_Intake',
      null,
      null
    );

    Assert.isTrue(result.success, 'Errors: ' + result.errors);
    Assert.areEqual(1, result.fieldsApplied, 'Name extracted');
    Assert.areEqual(1, result.fieldsCompared, 'Phone checked');
    Assert.areEqual(1, result.mismatches.size(), 'Phone differs');
    Assert.isFalse(result.compliant);
    Assert.areEqual(
      'Jane Doe',
      [SELECT SuppliedName FROM Case LIMIT 1].SuppliedName,
      'Extraction rule must still write'
    );
    Assert.areEqual(
      '555-EXISTING',
      [SELECT Phone FROM Account LIMIT 1].Phone,
      'Compliance rule must not write'
    );
  }

  @IsTest
  static void mismatchHandlerCreatesTaskOnCase() {
    Id contentDocumentId = setupCaseWithFile();
    Id caseId = [SELECT Id FROM Case LIMIT 1].Id;
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      // Description blank → guaranteed mismatch on the Case.
      makeRule('estate.description', 'Case', 'Description', 'Always', null)
    };

    Test.startTest();
    JsonMappingService.Result result = JsonMappingService.applyMappings(
      contentDocumentId,
      '{"estate":{"description":"From the form"}}',
      'Estate_Intake',
      'Compliance',
      'ComplianceTaskHandler'
    );
    Test.stopTest();

    Assert.isTrue(result.success, 'Errors: ' + result.errors);
    Assert.areEqual(1, result.mismatches.size());
    List<Task> tasks = [SELECT WhatId, Subject, Description FROM Task];
    Assert.areEqual(1, tasks.size(), 'Handler should create one Task');
    Assert.areEqual(caseId, tasks[0].WhatId, 'Task should sit on the Case');
    Assert.areEqual('Review compliance mismatches', tasks[0].Subject);
    Assert.isTrue(
      tasks[0].Description.contains('Case.Description'),
      'Description should list the mismatch: ' + tasks[0].Description
    );
  }

  @IsTest
  static void reportsBadHandlerAndBadMode() {
    Id contentDocumentId = setupCaseWithFile();
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      makeRule('estate.description', 'Case', 'Description', 'Always', null)
    };
    String jsonString = '{"estate":{"description":"From the form"}}';

    JsonMappingService.Result missing = JsonMappingService.applyMappings(
      contentDocumentId,
      jsonString,
      'Estate_Intake',
      'Compliance',
      'NoSuchHandler99'
    );
    Assert.isFalse(missing.success);
    Assert.isTrue(
      missing.errors[0].contains('was not found'),
      'Got: ' + missing.errors
    );

    JsonMappingService.Result wrongType = JsonMappingService.applyMappings(
      contentDocumentId,
      jsonString,
      'Estate_Intake',
      'Compliance',
      'JsonPathReader'
    );
    Assert.isFalse(wrongType.success);
    Assert.isTrue(
      wrongType.errors[0].contains('does not implement'),
      'Got: ' + wrongType.errors
    );

    JsonMappingService.Result badMode = JsonMappingService.applyMappings(
      contentDocumentId,
      jsonString,
      'Estate_Intake',
      'Bogus',
      null
    );
    Assert.isFalse(badMode.success);
    Assert.isTrue(
      badMode.errors[0].contains('Unknown mode'),
      'Got: ' + badMode.errors
    );
  }

  @IsTest
  static void valuesMatchIsTypeAware() {
    Assert.isTrue(JsonMappingService.valuesMatch('Jane Doe', ' JANE  DOE '));
    Assert.isFalse(JsonMappingService.valuesMatch('Jane', 'John'));
    Assert.isFalse(JsonMappingService.valuesMatch('Jane', null));
    Assert.isFalse(JsonMappingService.valuesMatch('Jane', ''));
    Assert.isTrue(JsonMappingService.valuesMatch(1234.56, 1234.56));
    Assert.isTrue(
      JsonMappingService.valuesMatch(5, Decimal.valueOf('5.0')),
      'Integer vs Decimal boxing must not matter'
    );
    Assert.isFalse(JsonMappingService.valuesMatch(5, 6));
    Assert.isTrue(
      JsonMappingService.valuesMatch(
        Date.newInstance(2026, 7, 31),
        Date.newInstance(2026, 7, 31)
      )
    );
    Assert.isTrue(JsonMappingService.valuesMatch(true, true));
    Assert.isFalse(JsonMappingService.valuesMatch(true, false));
  }

  @IsTest
  static void resolvesOpportunityLinkedDirectly() {
    Opportunity opportunity = new Opportunity(
      Name = 'Estate Opportunity',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30)
    );
    insert opportunity;
    ContentVersion cv = new ContentVersion(
      Title = 'Deal sheet',
      PathOnClient = 'deal.pdf',
      VersionData = Blob.valueOf('pdf bytes')
    );
    insert cv;
    Id contentDocumentId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      ContentDocumentId = contentDocumentId,
      LinkedEntityId = opportunity.Id,
      ShareType = 'V'
    );
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      makeRule('deal.notes', 'Opportunity', 'Description', 'Always', null)
    };

    JsonMappingService.Result result = JsonMappingService.applyMappings(
      contentDocumentId,
      '{"deal":{"notes":"Reviewed against the deal sheet"}}',
      'Deal_Intake',
      null,
      null
    );

    Assert.isTrue(result.success, 'Errors: ' + result.errors);
    Assert.areEqual(
      'Reviewed against the deal sheet',
      [SELECT Description FROM Opportunity WHERE Id = :opportunity.Id]
      .Description,
      'A non-Case object linked to the file must resolve and update'
    );
  }

  @IsTest
  static void anchorFilterSelectsAmongChildRecords() {
    // File linked to the Account only; the Case anchor is found via the
    // child hop (Case.AccountId = :accountId). Two candidate Cases exist —
    // the Anchor_Filter__c picks one.
    Account account = new Account(Name = 'Estate Holder');
    insert account;
    insert new List<Case>{
      new Case(AccountId = account.Id, Subject = 'Case A'),
      new Case(AccountId = account.Id, Subject = 'Case B')
    };
    ContentVersion cv = new ContentVersion(
      Title = 'Scanned form',
      PathOnClient = 'form.pdf',
      VersionData = Blob.valueOf('pdf bytes')
    );
    insert cv;
    Id contentDocumentId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      ContentDocumentId = contentDocumentId,
      LinkedEntityId = account.Id,
      ShareType = 'V'
    );

    JSON_Field_Mapping__mdt constantFilter = makeRule(
      'estate.description',
      'Case',
      'Description',
      'Always',
      null
    );
    constantFilter.Anchor_Filter__c = 'Subject = \'Case B\'';
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      constantFilter
    };
    JsonMappingService.Result result = JsonMappingService.applyMappings(
      contentDocumentId,
      '{"estate":{"description":"For B"}}',
      'Estate_Intake',
      null,
      null
    );
    Assert.isTrue(result.success, 'Errors: ' + result.errors);
    Assert.areEqual(
      'For B',
      [SELECT Description FROM Case WHERE Subject = 'Case B'].Description,
      'The filtered sibling must receive the value'
    );
    Assert.isNull(
      [SELECT Description FROM Case WHERE Subject = 'Case A'].Description,
      'The other sibling must stay untouched'
    );

    // Same graph, but the filter binds a value from the reviewed JSON.
    JSON_Field_Mapping__mdt jsonFilter = makeRule(
      'estate.description',
      'Case',
      'Description',
      'Always',
      null
    );
    jsonFilter.Anchor_Filter__c = 'Subject = {json:caseSubject}';
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      jsonFilter
    };
    JsonMappingService.Result tokenResult = JsonMappingService.applyMappings(
      contentDocumentId,
      '{"caseSubject":"Case A","estate":{"description":"For A"}}',
      'Estate_Intake',
      null,
      null
    );
    Assert.isTrue(tokenResult.success, 'Errors: ' + tokenResult.errors);
    Assert.areEqual(
      'For A',
      [SELECT Description FROM Case WHERE Subject = 'Case A'].Description,
      'The {json:path} token must select the sibling named in the document'
    );
  }

  @IsTest
  static void reportsUnreachableObjectAndUnknownField() {
    Id contentDocumentId = setupCaseWithFile();
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      makeRule('a', 'Opportunity', 'Name', 'Always', null),
      makeRule('b', 'Case', 'No_Such_Field__c', 'Always', null),
      makeRule('applicant.name', 'Case', 'SuppliedName', 'Always', null)
    };

    JsonMappingService.Result result = JsonMappingService.applyMappings(
      contentDocumentId,
      '{"a":"x","b":"y","applicant":{"name":"Jane"}}',
      'Estate_Intake',
      null,
      null
    );

    Assert.isFalse(result.success, 'Rule problems should be reported');
    Assert.areEqual(2, result.errors.size(), 'Errors: ' + result.errors);
    Assert.areEqual(
      1,
      result.fieldsApplied,
      'The valid rule must still apply (partial success)'
    );
    Assert.areEqual(
      'Jane',
      [SELECT SuppliedName FROM Case LIMIT 1].SuppliedName
    );
  }

  @IsTest
  static void failsOnInvalidJsonAndEmptyMappingSet() {
    Id contentDocumentId = setupCaseWithFile();

    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      makeRule('a', 'Case', 'Subject', 'Always', null)
    };
    JsonMappingService.Result badJson = JsonMappingService.applyMappings(
      contentDocumentId,
      'not json at all {',
      'Estate_Intake',
      null,
      null
    );
    Assert.isFalse(badJson.success);
    Assert.isTrue(
      badJson.errors[0].contains('could not be parsed'),
      'Got: ' + badJson.errors
    );

    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>();
    JsonMappingService.Result noRules = JsonMappingService.applyMappings(
      contentDocumentId,
      '{}',
      'Unknown_Set',
      null,
      null
    );
    Assert.isFalse(noRules.success);
    Assert.isTrue(
      noRules.errors[0].contains('No active JSON Field Mapping rules'),
      'Got: ' + noRules.errors
    );
  }

  @IsTest
  static void invocableProcessesRequests() {
    Id contentDocumentId = setupCaseWithFile();
    JsonMappingSelector.testRules = new List<JSON_Field_Mapping__mdt>{
      makeRule('applicant.name', 'Case', 'SuppliedName', 'Always', null)
    };
    JsonMappingService.Request request = new JsonMappingService.Request();
    request.contentDocumentId = contentDocumentId;
    request.jsonString = '{"applicant":{"name":"Flow User"}}';
    request.mappingSetName = 'Estate_Intake';

    List<JsonMappingService.Result> results = JsonMappingService.apply(
      new List<JsonMappingService.Request>{ request }
    );

    Assert.areEqual(1, results.size());
    Assert.isTrue(results[0].success, 'Errors: ' + results[0].errors);
  }

  @IsTest
  static void pathReaderNavigatesObjectsAndArrays() {
    Object root = JSON.deserializeUntyped(
      '{"a":{"b":[{"c":"deep"},{"c":"deeper"}]},"n":5}'
    );
    Assert.areEqual('deep', JsonPathReader.read(root, 'a.b[0].c'));
    Assert.areEqual('deeper', JsonPathReader.read(root, 'a.b[1].c'));
    Assert.areEqual(5, JsonPathReader.read(root, 'n'));
    Assert.isNull(JsonPathReader.read(root, 'a.missing.c'));
    Assert.isNull(JsonPathReader.read(root, 'a.b[9].c'));
    Assert.isNull(JsonPathReader.read(root, 'a.b[x].c'));
    Assert.isNull(JsonPathReader.read(root, 'n.b'));
    Assert.isNull(JsonPathReader.read(null, 'a'));
    Assert.isNull(JsonPathReader.read(root, ''));
  }

  @IsTest
  static void coercerConvertsCommonTypes() {
    Schema.DescribeFieldResult dateField = Case.SlaStartDate.getDescribe(); // DATETIME
    Schema.DescribeFieldResult boolField = Case.IsEscalated.getDescribe();
    Schema.DescribeFieldResult textField = Case.Subject.getDescribe();
    Schema.DescribeFieldResult numberField = Account.NumberOfEmployees.getDescribe();
    Schema.DescribeFieldResult amountField = Opportunity.Amount.getDescribe();
    Schema.DescribeFieldResult dobField = Contact.Birthdate.getDescribe();

    Assert.areEqual(true, FieldValueCoercer.coerce(boolField, 'Yes', null));
    Assert.areEqual(false, FieldValueCoercer.coerce(boolField, '0', null));
    Assert.areEqual(
      'hello',
      FieldValueCoercer.coerce(textField, 'hello', null)
    );
    Assert.areEqual(1234, FieldValueCoercer.coerce(numberField, '1,234', null));
    Assert.areEqual(
      1234.56,
      FieldValueCoercer.coerce(amountField, 'R 1,234.56', null)
    );
    Assert.areEqual(
      Date.newInstance(2026, 7, 31),
      FieldValueCoercer.coerce(dobField, '2026-07-31', null)
    );
    Assert.areEqual(
      Date.newInstance(2026, 7, 31),
      FieldValueCoercer.coerce(dobField, '31/07/2026', 'dd/MM/yyyy')
    );
    Assert.areEqual(
      Date.newInstance(2026, 7, 31),
      FieldValueCoercer.coerce(dobField, '07/31/2026', 'MM/dd/yyyy')
    );
    Assert.isNotNull(
      FieldValueCoercer.coerce(dateField, '2026-07-31T10:15:00Z', null)
    );
    Assert.isNull(FieldValueCoercer.coerce(textField, null, null));
  }

  @IsTest
  static void coercerRejectsBadValues() {
    try {
      FieldValueCoercer.coerce(Case.IsEscalated.getDescribe(), 'maybe', null);
      Assert.fail('Expected CoercionException for bad boolean');
    } catch (FieldValueCoercer.CoercionException e) {
      Assert.isTrue(e.getMessage().contains('not a boolean'));
    }
    try {
      FieldValueCoercer.coerce(
        Account.NumberOfEmployees.getDescribe(),
        'many',
        null
      );
      Assert.fail('Expected CoercionException for bad number');
    } catch (FieldValueCoercer.CoercionException e) {
      Assert.isTrue(e.getMessage().contains('not a number'));
    }
    try {
      FieldValueCoercer.coerce(Contact.Birthdate.getDescribe(), 'soon', null);
      Assert.fail('Expected CoercionException for bad date');
    } catch (FieldValueCoercer.CoercionException e) {
      Assert.isTrue(e.getMessage().contains('not a valid date'));
    }
  }
}
