/*
 * Letters of Executorship example — finishes the setup.
 *
 * Links the scanned Letters to the seeded Case and prints the
 * ContentDocumentId the demo component needs. It also walks the same child
 * hop the mapping engine will walk (Case -> Estate_Case__c via Case__c) and
 * prints the Estate Case fields, so you can see they are blank before the run
 * and confirm the record the engine is going to write to.
 *
 *   sf apex run --file force-app/idp/examples/letters-of-executorship/scripts/setup.apex --target-org <alias>
 */
final String CASE_SUBJECT = 'Letters of Executorship received - Estate Late G P Botha';
final String FILE_TITLE = 'Letters of Executorship';

List<Case> seeded = [
  SELECT Id, CaseNumber, AccountId, Account.Name
  FROM Case
  WHERE Subject = :CASE_SUBJECT
  ORDER BY CreatedDate DESC
  LIMIT 1
];
if (seeded.isEmpty()) {
  throw new IllegalArgumentException(
    'No seeded Case found. Run the "sf project deploy start" and ' +
      '"sf data import tree" steps from the example README first.'
  );
}
Case intake = seeded[0];

// The same hop IdpContextResolver makes: the file hangs off the Case,
// and the Estate Case is found as its child. If this returns nothing, the
// engine will not find an Estate_Case__c to write to either.
List<Estate_Case__c> estates = [
  SELECT
    Id,
    Name,
    Estate_Number__c,
    Letters_Issued_Date__c,
    Masters_Office__c,
    Executor_Full_Name__c,
    Executor_ID_Number__c,
    Appointment_Capacity__c,
    Deceased_Full_Name__c,
    Deceased_ID_Number__c,
    Date_Of_Death__c
  FROM Estate_Case__c
  WHERE Case__c = :intake.Id
  ORDER BY CreatedDate DESC
  LIMIT 1
];
if (estates.isEmpty()) {
  throw new IllegalArgumentException(
    'The Case has no Estate_Case__c child. Check that the data import ran ' +
      'and that the lookup from Estate_Case__c to Case is named Case__c ' +
      '(see "If your org already has Estate_Case__c" in the README).'
  );
}
Estate_Case__c estate = estates[0];

// Related_Party__c has no seed data at all — the repeating section creates
// every row itself, so a non-zero count here would mean a previous run
// already applied the mapping.
Integer relatedPartyCount = [
  SELECT COUNT()
  FROM Related_Party__c
  WHERE Estate_Case__c = :estate.Id
];

List<ContentDocumentLink> links = [
  SELECT ContentDocumentId
  FROM ContentDocumentLink
  WHERE LinkedEntityId = :intake.Id
  ORDER BY SystemModstamp DESC
];

if (links.isEmpty()) {
  List<ContentDocument> documents = [
    SELECT Id
    FROM ContentDocument
    WHERE Title = :FILE_TITLE
    ORDER BY CreatedDate DESC
    LIMIT 1
  ];
  if (documents.isEmpty()) {
    throw new IllegalArgumentException(
      'No file titled "' +
        FILE_TITLE +
        '" exists in this org. Run the "sf data create file" step first.'
    );
  }
  insert new ContentDocumentLink(
    ContentDocumentId = documents[0].Id,
    LinkedEntityId = intake.Id,
    ShareType = 'V',
    Visibility = 'AllUsers'
  );
  links = [
    SELECT ContentDocumentId
    FROM ContentDocumentLink
    WHERE LinkedEntityId = :intake.Id
    ORDER BY SystemModstamp DESC
  ];
}

System.debug(LoggingLevel.ERROR, '=== Letters of Executorship example ===');
System.debug(
  LoggingLevel.ERROR,
  'Case ' + intake.CaseNumber + ' (' + intake.Id + ')'
);
System.debug(
  LoggingLevel.ERROR,
  'Account ' + intake.Account.Name + ' (' + intake.AccountId + ')'
);
System.debug(
  LoggingLevel.ERROR,
  'Estate Case ' + estate.Name + ' (' + estate.Id + ')  <- resolved by child hop'
);
System.debug(
  LoggingLevel.ERROR,
  'Content Document Id: ' + links[0].ContentDocumentId
);
System.debug(
  LoggingLevel.ERROR,
  'Mapping Set: Letters_Of_Executorship  |  Mode: Extraction'
);
System.debug(
  LoggingLevel.ERROR,
  '--- Estate Case fields before the run (all nine should be blank) ---'
);
System.debug(LoggingLevel.ERROR, '  Estate number       : ' + estate.Estate_Number__c);
System.debug(LoggingLevel.ERROR, '  Letters issued      : ' + estate.Letters_Issued_Date__c);
System.debug(LoggingLevel.ERROR, '  Master\'s office     : ' + estate.Masters_Office__c);
System.debug(LoggingLevel.ERROR, '  Executor name       : ' + estate.Executor_Full_Name__c);
System.debug(LoggingLevel.ERROR, '  Executor ID         : ' + estate.Executor_ID_Number__c);
System.debug(LoggingLevel.ERROR, '  Capacity            : ' + estate.Appointment_Capacity__c);
System.debug(LoggingLevel.ERROR, '  Deceased name       : ' + estate.Deceased_Full_Name__c);
System.debug(LoggingLevel.ERROR, '  Deceased ID         : ' + estate.Deceased_ID_Number__c);
System.debug(LoggingLevel.ERROR, '  Date of death       : ' + estate.Date_Of_Death__c);
System.debug(
  LoggingLevel.ERROR,
  '  Related Party rows  : ' + relatedPartyCount + ' (should be 0 before the run)'
);
