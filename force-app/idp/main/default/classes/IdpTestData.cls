/**
 * Shared test data builders for the IDP engine tests: records plus a file
 * linked to them, the shape every run starts from.
 */
@IsTest
public class IdpTestData {
  /** Account, Case and the ContentDocument linked to that Case. */
  public class CaseWithFile {
    public Account account;
    public Case caseRecord;
    public Id contentDocumentId;
  }

  /**
   * Builds the default Account, Case and linked file.
   *
   * @return Inserted records a run can start from.
   */
  public static CaseWithFile caseWithFile() {
    return caseWithFile('Estate Holder', '0821234567');
  }

  /**
   * Builds an Account, a Case under it and a file linked to that Case.
   *
   * @param accountName Name given to the Account.
   * @param phone Phone stored on the Account, for compliance comparisons.
   * @return Inserted records a run can start from.
   */
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

  /**
   * Uploads a ContentVersion and shares it with the supplied record.
   *
   * @param recordId Record the ContentDocument is linked to.
   * @param title Title of the uploaded file.
   * @return ContentDocumentId of the uploaded file.
   */
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
