/*
 * Consolidated statement example — finishes the setup.
 *
 * The statement covers the whole customer relationship, so the file is linked
 * to the Account rather than to a Case: the Statement section writes to that
 * Account, and the Holdings rows are the Assets hanging off it.
 *
 *   sf apex run --file force-app/idp/examples/consolidated-statement/scripts/setup.apex --target-org <alias>
 */
final String ACCOUNT_NAME = 'Cape Meridian Logistics';
final String FILE_TITLE = 'Consolidated Statement';

List<Account> seeded = [
  SELECT Id, Name
  FROM Account
  WHERE Name = :ACCOUNT_NAME
  ORDER BY CreatedDate DESC
  LIMIT 1
];
if (seeded.isEmpty()) {
  throw new IllegalArgumentException(
    'No seeded Account found. Run the "sf project deploy start" and ' +
      '"sf data import tree" steps from the example README first.'
  );
}
Account customer = seeded[0];

List<ContentDocumentLink> links = [
  SELECT ContentDocumentId
  FROM ContentDocumentLink
  WHERE LinkedEntityId = :customer.Id
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
    LinkedEntityId = customer.Id,
    ShareType = 'V',
    Visibility = 'AllUsers'
  );
  links = [
    SELECT ContentDocumentId
    FROM ContentDocumentLink
    WHERE LinkedEntityId = :customer.Id
    ORDER BY SystemModstamp DESC
  ];
}

System.debug(LoggingLevel.ERROR, '=== Consolidated statement example ===');
System.debug(
  LoggingLevel.ERROR,
  'Account ' + customer.Name + ' (' + customer.Id + ')'
);
System.debug(
  LoggingLevel.ERROR,
  'Content Document Id: ' + links[0].ContentDocumentId
);
System.debug(
  LoggingLevel.ERROR,
  'Mapping Set: Consolidated_Statement  |  Mode: Extraction'
);
for (Asset holding : [
  SELECT
    Product_Account_Number__c,
    Name,
    Account_Status__c,
    Current_Balance__c,
    InstallDate
  FROM Asset
  WHERE AccountId = :customer.Id
  ORDER BY Product_Account_Number__c
]) {
  System.debug(
    LoggingLevel.ERROR,
    '  row ' +
      holding.Product_Account_Number__c +
      ' | ' +
      holding.Name +
      ' | ' +
      holding.Account_Status__c +
      ' | balance ' +
      holding.Current_Balance__c +
      ' | opened ' +
      holding.InstallDate
  );
}
