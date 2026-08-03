@IsTest
private class FilePreviewControllerTest {
    private static ContentVersion insertFile(String name, String path, Blob body) {
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
