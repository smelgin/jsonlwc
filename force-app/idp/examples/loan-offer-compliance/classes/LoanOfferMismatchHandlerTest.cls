@IsTest
private class LoanOfferMismatchHandlerTest {
  @TestSetup
  static void seed() {
    Account borrower = new Account(
      Name = 'Kalahari Freight Services',
      Verified_Annual_Turnover__c = 14750000
    );
    insert borrower;
    insert new Case(
      AccountId = borrower.Id,
      Subject = 'Signed loan offer received',
      Offer_Reference__c = 'LN-2026-093315',
      Loan_Amount__c = 2400000,
      Interest_Rate_Offered__c = 11.25,
      Repayment_Amount__c = 51902.44,
      Offer_Verification_Status__c = 'Not Checked'
    );
  }

  /**
   * The handler updates the Case in USER_MODE, so the caller needs the
   * editable FLS the example ships in its permission set — freshly deployed
   * custom fields grant none by default, not even to an admin. A permission
   * set assigned to the *current* user does not refresh that user's FLS
   * mid-transaction (permissions are cached at the start of the request), so
   * the fix is to run the handler as a fresh user who carries the permission
   * set. That user reuses the running user's profile, so it keeps whatever
   * record access (e.g. Modify All) the deploying admin has and only the FLS
   * has to come from the permission set. Creating the user and assigning the
   * set inside System.runAs isolates this setup-object DML from the handler's
   * later record DML, sidestepping MIXED_DML_OPERATION.
   */
  private static User userWithExampleAccess() {
    PermissionSet ps = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'IDP_Example_Loan_Offer_Compliance'
      LIMIT 1
    ];
    User runner = new User(
      ProfileId = UserInfo.getProfileId(),
      LastName = 'Loan Offer Example',
      Alias = 'idploe',
      Email = 'idp.loanoffer.example@example.com.invalid',
      Username = 'idp.loanoffer.' +
        DateTime.now().getTime() +
        '@example.com.invalid',
      TimeZoneSidKey = 'GMT',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert runner;
      insert new PermissionSetAssignment(
        AssigneeId = runner.Id,
        PermissionSetId = ps.Id
      );
    }
    return runner;
  }

  private static IdpResult.Finding mismatch(
    String objectName,
    Id recordId,
    String fieldName,
    String jsonPath,
    String extracted,
    String stored
  ) {
    IdpResult.Finding finding = new IdpResult.Finding();
    finding.code = IdpResult.CODE_VALUE_MISMATCH;
    finding.severity = IdpResult.SEV_WARNING;
    finding.objectName = objectName;
    finding.recordId = recordId;
    finding.fieldName = fieldName;
    finding.jsonPath = jsonPath;
    finding.extractedValue = extracted;
    finding.storedValue = stored;
    finding.compareOutcome = 'Mismatch';
    return finding;
  }

  private static IdpResult.RunReport reportOf(
    List<IdpResult.Finding> mismatches
  ) {
    IdpResult.Result result = new IdpResult.Result();
    if (mismatches != null) {
      for (IdpResult.Finding finding : mismatches) {
        result.findings.add(finding);
        result.compliant = false;
      }
      if (mismatches.isEmpty()) {
        result.compliant = true;
      }
    }
    IdpResult.RunReport report = new IdpResult.RunReport();
    report.mappingSetName = 'Loan_Offer_Compliance';
    report.mode = 'Compliance';
    report.results = new List<IdpResult.Result>{ result };
    return report;
  }

  @IsTest
  static void stampsTheCaseAndRaisesOneTask() {
    User runner = userWithExampleAccess();
    Case offer = [SELECT Id, AccountId FROM Case LIMIT 1];
    IdpResult.RunReport report = reportOf(
      new List<IdpResult.Finding>{
        mismatch(
          'Account',
          offer.AccountId,
          'Credit_Risk_Grade__c',
          'borrower.creditRiskGrade',
          'BB',
          null
        ),
        mismatch(
          'Case',
          offer.Id,
          'Interest_Rate_Offered__c',
          'offer.interestRate',
          '12.05',
          '11.25'
        )
      }
    );

    Test.startTest();
    System.runAs(runner) {
      new LoanOfferMismatchHandler().handle(report);
    }
    Test.stopTest();

    Case updated = [
      SELECT Offer_Verification_Status__c, Offer_Verification_Notes__c
      FROM Case
      WHERE Id = :offer.Id
    ];
    Assert.areEqual(
      'Mismatched',
      updated.Offer_Verification_Status__c,
      'The Case should be stamped as mismatched.'
    );
    Assert.isTrue(
      updated.Offer_Verification_Notes__c.contains('Interest_Rate_Offered__c'),
      'The notes should name the field that differed.'
    );
    Assert.isTrue(
      updated.Offer_Verification_Notes__c.contains('(blank)'),
      'A blank stored value should be rendered as (blank).'
    );

    List<Task> tasks = [SELECT WhatId, Priority, Description FROM Task];
    Assert.areEqual(1, tasks.size(), 'One Task per non-compliant document.');
    Assert.areEqual(
      offer.Id,
      tasks[0].WhatId,
      'The Task belongs on the Case when one is among the mismatches.'
    );
    Assert.areEqual('High', tasks[0].Priority, 'Offer differences are urgent.');
    Assert.isTrue(
      tasks[0].Description.contains('Account (1)') &&
      tasks[0].Description.contains('Case (1)'),
      'Differences should be grouped by object.'
    );
  }

  @IsTest
  static void fallsBackToTheFirstRecordWhenNoCaseDiffers() {
    Account borrower = [SELECT Id FROM Account LIMIT 1];
    IdpResult.RunReport report = reportOf(
      new List<IdpResult.Finding>{
        mismatch(
          'Account',
          borrower.Id,
          'Verified_Annual_Turnover__c',
          'borrower.verifiedAnnualTurnover',
          '14750000',
          '9100000'
        )
      }
    );

    Test.startTest();
    new LoanOfferMismatchHandler().handle(report);
    Test.stopTest();

    List<Task> tasks = [SELECT WhatId FROM Task];
    Assert.areEqual(1, tasks.size(), 'The Task is raised regardless.');
    Assert.areEqual(
      borrower.Id,
      tasks[0].WhatId,
      'With no Case among the mismatches it hangs off the first record.'
    );
    Assert.areEqual(
      'Not Checked',
      [SELECT Offer_Verification_Status__c FROM Case LIMIT 1]
      .Offer_Verification_Status__c,
      'A Case that did not differ must not be stamped.'
    );
  }

  @IsTest
  static void doesNothingWithoutMismatches() {
    Test.startTest();
    new LoanOfferMismatchHandler()
      .handle(reportOf(new List<IdpResult.Finding>()));
    new LoanOfferMismatchHandler().handle(reportOf(null));
    new LoanOfferMismatchHandler().handle(null);
    Test.stopTest();

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Task],
      'A compliant run raises nothing.'
    );
  }
}
