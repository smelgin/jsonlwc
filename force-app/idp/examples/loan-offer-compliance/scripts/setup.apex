/*
 * Loan offer compliance example — finishes the setup.
 *
 * Links the signed offer letter to the seeded Case and prints both the
 * ContentDocumentId and the stored terms, so you can see exactly which two
 * values the document is about to disagree with.
 *
 *   sf apex run --file force-app/idp/examples/loan-offer-compliance/scripts/setup.apex --target-org <alias>
 */
final String CASE_SUBJECT = 'Signed loan offer received - Kalahari Freight Services';
final String FILE_TITLE = 'Signed Loan Offer Letter';

List<Case> seeded = [
  SELECT
    Id,
    CaseNumber,
    AccountId,
    Account.Name,
    Account.Credit_Risk_Grade__c,
    Account.Verified_Annual_Turnover__c,
    Offer_Reference__c,
    Loan_Amount__c,
    Interest_Rate_Offered__c,
    Loan_Term_Months__c,
    Repayment_Amount__c,
    Offer_Expiry_Date__c,
    Offer_Verification_Status__c
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
Case offer = seeded[0];

List<ContentDocumentLink> links = [
  SELECT ContentDocumentId
  FROM ContentDocumentLink
  WHERE LinkedEntityId = :offer.Id
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
    LinkedEntityId = offer.Id,
    ShareType = 'V',
    Visibility = 'AllUsers'
  );
  links = [
    SELECT ContentDocumentId
    FROM ContentDocumentLink
    WHERE LinkedEntityId = :offer.Id
    ORDER BY SystemModstamp DESC
  ];
}

System.debug(LoggingLevel.ERROR, '=== Loan offer compliance example ===');
System.debug(
  LoggingLevel.ERROR,
  'Case ' + offer.CaseNumber + ' (' + offer.Id + ')'
);
System.debug(
  LoggingLevel.ERROR,
  'Account ' + offer.Account.Name + ' (' + offer.AccountId + ')'
);
System.debug(
  LoggingLevel.ERROR,
  'Content Document Id: ' + links[0].ContentDocumentId
);
System.debug(
  LoggingLevel.ERROR,
  'Mapping Set: Loan_Offer_Compliance  |  Mode: Compliance  |  ' +
    'Handler: LoanOfferMismatchHandler'
);
System.debug(LoggingLevel.ERROR, '--- stored terms the document is checked against ---');
System.debug(
  LoggingLevel.ERROR,
  '  Credit risk grade      : ' +
    (offer.Account.Credit_Risk_Grade__c == null
      ? '(blank -> will mismatch)'
      : offer.Account.Credit_Risk_Grade__c)
);
System.debug(
  LoggingLevel.ERROR,
  '  Verified turnover      : ' + offer.Account.Verified_Annual_Turnover__c
);
System.debug(LoggingLevel.ERROR, '  Offer reference        : ' + offer.Offer_Reference__c);
System.debug(LoggingLevel.ERROR, '  Principal              : ' + offer.Loan_Amount__c);
System.debug(
  LoggingLevel.ERROR,
  '  Interest rate          : ' +
    offer.Interest_Rate_Offered__c +
    '  (document says 12.05 -> will mismatch)'
);
System.debug(LoggingLevel.ERROR, '  Term (months)          : ' + offer.Loan_Term_Months__c);
System.debug(
  LoggingLevel.ERROR,
  '  Monthly repayment      : ' +
    offer.Repayment_Amount__c +
    '  (document says 53480.19 -> will mismatch)'
);
System.debug(LoggingLevel.ERROR, '  Offer expiry           : ' + offer.Offer_Expiry_Date__c);
System.debug(
  LoggingLevel.ERROR,
  '  Verification status    : ' + offer.Offer_Verification_Status__c
);
