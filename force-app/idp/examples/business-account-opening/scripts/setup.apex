/*
 * Business account opening example — finishes the setup.
 *
 * Run it after deploying the metadata, importing the data and uploading the
 * sample PDF. It links the file to the seeded Case if the upload did not,
 * then prints the ContentDocumentId that fileJsonReview needs.
 *
 *   sf apex run --file force-app/idp/examples/business-account-opening/scripts/setup.apex --target-org <alias>
 */
final String CASE_SUBJECT = 'Business account opening - Blue Harbour Trading';
final String FILE_TITLE = 'Business Account Opening Application';

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
Case application = seeded[0];

List<ContentDocumentLink> links = [
  SELECT ContentDocumentId, ContentDocument.Title
  FROM ContentDocumentLink
  WHERE LinkedEntityId = :application.Id
  ORDER BY SystemModstamp DESC
];

if (links.isEmpty()) {
  // The file was uploaded somewhere else (or with a different --parent-id):
  // find it by title and link it to the Case so the resolver can reach it.
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
    LinkedEntityId = application.Id,
    ShareType = 'V',
    Visibility = 'AllUsers'
  );
  links = [
    SELECT ContentDocumentId, ContentDocument.Title
    FROM ContentDocumentLink
    WHERE LinkedEntityId = :application.Id
    ORDER BY SystemModstamp DESC
  ];
}

System.debug(LoggingLevel.ERROR, '=== Business account opening example ===');
System.debug(
  LoggingLevel.ERROR,
  'Case ' + application.CaseNumber + ' (' + application.Id + ')'
);
System.debug(
  LoggingLevel.ERROR,
  'Account ' + application.Account.Name + ' (' + application.AccountId + ')'
);
System.debug(
  LoggingLevel.ERROR,
  'Content Document Id: ' + links[0].ContentDocumentId
);
System.debug(
  LoggingLevel.ERROR,
  'Mapping Set: Account_Opening_Intake  |  Mode: Extraction'
);
