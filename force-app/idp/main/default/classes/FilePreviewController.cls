/**
 * Resolves the metadata and (for small files) the bytes a Lightning
 * component needs to preview a file stored in Salesforce Files
 * (ContentDocument / ContentVersion).
 */
public with sharing class FilePreviewController {
  /**
   * Largest file we will base64-encode for inline PDF.js rendering.
   * Kept well under the 6 MB synchronous Apex heap limit; larger files
   * fall back to the browser's native preview on the client.
   */
  @TestVisible
  private static final Integer MAX_PREVIEW_BYTES = 3 * 1024 * 1024;

  /**
   * Returns title, extension, size and latest version id for a
   * ContentDocument. Runs in user mode so record access follows the
   * running user's sharing.
   */
  @AuraEnabled(cacheable=true)
  public static FileInfo getFileInfo(Id contentDocumentId) {
    List<ContentDocument> docs = [
      SELECT Title, FileExtension, ContentSize, LatestPublishedVersionId
      FROM ContentDocument
      WHERE Id = :contentDocumentId
      WITH USER_MODE
      LIMIT 1
    ];
    if (docs.isEmpty()) {
      throw notAccessible(contentDocumentId);
    }
    FileInfo info = new FileInfo();
    info.title = docs[0].Title;
    info.fileExtension = docs[0].FileExtension == null
      ? ''
      : docs[0].FileExtension.toLowerCase();
    info.contentSize = docs[0].ContentSize;
    info.contentVersionId = docs[0].LatestPublishedVersionId;
    return info;
  }

  /**
   * Returns the file's bytes, base64-encoded, for a ContentVersion.
   * The size is checked before the binary is loaded so an oversized file
   * never consumes heap. Throws if the file is missing or too large;
   * callers are expected to fall back to a native preview on error.
   */
  @AuraEnabled(cacheable=true)
  public static String getFileBase64(Id contentVersionId) {
    List<ContentVersion> sized = [
      SELECT ContentSize
      FROM ContentVersion
      WHERE Id = :contentVersionId
      WITH USER_MODE
      LIMIT 1
    ];
    if (sized.isEmpty()) {
      throw notAccessible(contentVersionId);
    }
    if (sized[0].ContentSize > MAX_PREVIEW_BYTES) {
      throw newException(
        'File is too large for inline rendering (' +
          sized[0].ContentSize +
          ' bytes).'
      );
    }
    ContentVersion cv = [
      SELECT VersionData
      FROM ContentVersion
      WHERE Id = :contentVersionId
      WITH USER_MODE
      LIMIT 1
    ];
    return EncodingUtil.base64Encode(cv.VersionData);
  }

  private static AuraHandledException notAccessible(Id recordId) {
    return newException('File not found or not accessible: ' + recordId);
  }

  private static AuraHandledException newException(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    return ex;
  }

  public class FileInfo {
    @AuraEnabled
    public String title;
    @AuraEnabled
    public String fileExtension;
    @AuraEnabled
    public Integer contentSize;
    @AuraEnabled
    public Id contentVersionId;
  }
}
