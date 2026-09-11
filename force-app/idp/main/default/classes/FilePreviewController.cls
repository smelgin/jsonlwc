/**
 * Resolves the metadata and (for small files) the bytes a Lightning
 * component needs to preview a file stored in Salesforce Files
 * (ContentDocument / ContentVersion).
 *
 * @group File Preview
 * @author Ernesto S Melgin
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
   * Resolves title, extension, size and latest version of a ContentDocument.
   *
   * Runs in user mode so record access follows the running user's sharing.
   *
   * @param contentDocumentId ContentDocument to describe.
   * @return Metadata the component needs to choose a preview strategy.
   * @throws AuraHandledException When the file is missing or not accessible.
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
   * Loads a ContentVersion's bytes for inline PDF.js rendering.
   *
   * The size is checked before the binary is loaded, so an oversized file
   * never consumes heap. Callers fall back to a native preview on error.
   *
   * @param contentVersionId ContentVersion whose bytes are requested.
   * @return Base64-encoded file content.
   * @throws AuraHandledException When the file is missing, not accessible,
   *         or larger than the inline rendering ceiling.
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

  /**
   * Builds the error raised when a file is absent or out of the user's reach.
   *
   * @param recordId File record the caller asked for.
   * @return Exception carrying a client-safe message.
   */
  private static AuraHandledException notAccessible(Id recordId) {
    return newException('File not found or not accessible: ' + recordId);
  }

  /**
   * Builds an exception whose message survives the trip to the client.
   *
   * @param message Text shown to the running user.
   * @return Exception with the message set for Lightning consumption.
   */
  private static AuraHandledException newException(String message) {
    AuraHandledException ex = new AuraHandledException(message);
    ex.setMessage(message);
    return ex;
  }

  /** ContentDocument metadata handed to the preview component. */
  public class FileInfo {
    /** File title as stored in Salesforce Files. */
    @AuraEnabled
    public String title;
    /** Lowercased file extension, empty when the document carries none. */
    @AuraEnabled
    public String fileExtension;
    /** File size in bytes, used to choose between inline and native preview. */
    @AuraEnabled
    public Integer contentSize;
    /** Latest published version, the record the bytes are read from. */
    @AuraEnabled
    public Id contentVersionId;
  }
}
