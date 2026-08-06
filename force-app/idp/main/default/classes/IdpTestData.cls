/**
 * Shared test data builders for the IDP engine tests: records plus a file
 * linked to them, the shape every run starts from.
 */
@IsTest
public class IdpTestData {
  public class CaseWithFile {
    public Account account;
    public Case caseRecord;
    public Id contentDocumentId;
  }

  /** Account + Case + a file linked to the Case. */
  public static CaseWithFile caseWithFile() {
    return caseWithFile('Estate Holder', '0821234567');
  }

  public static CaseWithFile caseWithFile(String accountName, String phone) {
    CaseWithFile data = new CaseWithFile();
    data.account = new Account(Name = accountName, Phone = phone);
    insert data.account;
    data.caseRecord = new Case(
      AccountId = data.account.Id,
      Subject = 'Estate intake'
    );
    insert data.caseRecord;
    data.contentDocumentId = linkFile(data.caseRecord.Id, 'Scanned form');
    return data;
  }

  /** Uploads a file and links it to the record; returns the ContentDocumentId. */
  public static Id linkFile(Id recordId, String title) {
    ContentVersion version = new ContentVersion(
      Title = title,
      PathOnClient = title.replace(' ', '-') + '.pdf',
      VersionData = Blob.valueOf('pdf bytes')
    );
    insert version;
    Id contentDocumentId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :version.Id
    ]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      ContentDocumentId = contentDocumentId,
      LinkedEntityId = recordId,
      ShareType = 'V'
    );
    return contentDocumentId;
  }
}
