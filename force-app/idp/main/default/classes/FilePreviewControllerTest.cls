/**
 * Unit tests for FilePreviewController.
 *
 * Validates metadata lookup, inline byte loading and the errors raised for
 * files that are missing or out of the running user's reach.
 */
@IsTest
private class FilePreviewControllerTest {
  /**
   * Uploads a file and reads back its document link.
   *
   * @param name Title of the file.
   * @param path Path on client, which decides the extension.
   * @param body File content.
   * @return The inserted ContentVersion with its ContentDocumentId.
   */
  private static ContentVersion insertFile(
    String name,
    String path,
    Blob body
  ) {
    ContentVersion cv = new ContentVersion(
      Title = name,
      PathOnClient = path,
      VersionData = body
    );
    insert cv;
    return [
      SELECT Id, ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ];
  }

  /**
   * Verifies that an existing document reports its title, lowercased
   * extension, size and latest version.
   */
  @IsTest
  static void returnsFileInfoForExistingDocument() {
    ContentVersion cv = insertFile(
      'Test File',
      'test.PDF',
      Blob.valueOf('dummy content')
    );

    Test.startTest();
    FilePreviewController.FileInfo info = FilePreviewController.getFileInfo(
      cv.ContentDocumentId
    );
    Test.stopTest();

    Assert.areEqual('Test File', info.title, 'Title should match');
    Assert.areEqual(
      'pdf',
      info.fileExtension,
      'Extension should be lowercased'
    );
    Assert.areEqual(
      Blob.valueOf('dummy content').size(),
      info.contentSize,
      'Content size should be returned'
    );
    Assert.isNotNull(
      info.contentVersionId,
      'Latest version id should be returned'
    );
  }

  /**
   * Verifies that a ContentDocument the user cannot reach raises an
   * explanatory AuraHandledException.
   */
  @IsTest
  static void throwsForUnknownDocument() {
    Id missingId = Id.valueOf('069000000000000AAA');
    try {
      FilePreviewController.getFileInfo(missingId);
      Assert.fail('Expected AuraHandledException');
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().contains('not accessible'),
        'Message should explain the failure: ' + e.getMessage()
      );
    }
  }

  /**
   * Verifies that a file under the inline ceiling comes back base64
   * encoded, byte for byte.
   */
  @IsTest
  static void returnsBase64ForSmallFile() {
    Blob body = Blob.valueOf('hello world');
    ContentVersion cv = insertFile('Small', 'small.pdf', body);

    Test.startTest();
    String encoded = FilePreviewController.getFileBase64(cv.Id);
    Test.stopTest();

    Assert.areEqual(
      EncodingUtil.base64Encode(body),
      encoded,
      'Should return the base64 of the file bytes'
    );
  }

  /**
   * Verifies that a ContentVersion the user cannot reach raises an
   * explanatory AuraHandledException.
   */
  @IsTest
  static void throwsForUnknownVersion() {
    Id missingId = Id.valueOf('068000000000000AAA');
    try {
      FilePreviewController.getFileBase64(missingId);
      Assert.fail('Expected AuraHandledException');
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().contains('not accessible'),
        'Message should explain the failure: ' + e.getMessage()
      );
    }
  }
}
