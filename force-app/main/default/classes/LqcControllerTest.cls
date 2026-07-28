@IsTest
private class LqcControllerTest {

    private static Case makeCase() {
        Case c = new Case(Subject = 'LQC Test Case', Status = 'New', Origin = 'Web');
        insert c;
        return c;
    }

    @IsTest
    static void getConfigReturnsDefaultJson() {
        // Custom metadata records are visible in tests without seeAllData.
        String config = LqcController.getConfig(null);
        System.assert(String.isNotBlank(config), 'Default config JSON should be returned');
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(config);
        System.assert(parsed.containsKey('tabs'), 'Config should contain a tabs array');
    }

    @IsTest
    static void getConfigThrowsForUnknownName() {
        try {
            LqcController.getConfig('DoesNotExist');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void saveAndReadResultRoundTrip() {
        Case c = makeCase();
        String payload = '{"version":1,"published":false,"tabs":{"shares":[]}}';

        Test.startTest();
        // Nothing stored yet for this Case.
        System.assertEquals(null, LqcController.getSavedResult(c.Id, null));
        // Save creates the Estate Case, then a second save updates it.
        LqcController.saveResult(c.Id, payload, null);
        LqcController.saveResult(c.Id, payload, null);
        String stored = LqcController.getSavedResult(c.Id, null);
        Test.stopTest();

        System.assertEquals(payload, stored, 'Saved payload should round-trip');
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Estate_Case__c],
            'Saving twice must reuse the same Estate Case'
        );
    }

    @IsTest
    static void storageClassNameDefaultsAndOverrides() {
        System.assertEquals(
            'LqcEstateCaseStorage',
            LqcController.storageClassName('{"tabs":[]}'),
            'Absent storageClass falls back to the Estate Case strategy'
        );
        System.assertEquals(
            'lqcEstateCaseStorage',
            LqcController.storageClassName('{"storageClass":"lqcEstateCaseStorage","tabs":[]}')
        );
        System.assertEquals(
            'LqcEstateCaseStorage',
            LqcController.storageClassName('{"storageClass":"  ","tabs":[]}'),
            'Blank storageClass falls back too'
        );
    }

    @IsTest
    static void defaultStorageStrategyIsResolvable() {
        ILqcStorage storage = LqcController.storageFor(null);
        System.assert(
            storage instanceof LqcEstateCaseStorage,
            'DE_LQC config should resolve to the Estate Case strategy'
        );
    }

    @IsTest
    static void estateCaseStorageFindsTheCaseLookup() {
        String lookup = LqcEstateCaseStorage.caseLookup();
        System.assert(
            String.isNotBlank(lookup),
            'Estate_Case__c must expose a lookup to Case'
        );
    }

    @IsTest
    static void refreshRowsRunsEveryConfiguredStub() {
        Case c = makeCase();
        Map<String, Integer> expectedCounts = new Map<String, Integer>{
            'LqcDebitAccounts' => 2,
            'LqcCreditAccounts' => 2,
            'LqcInsurancePolicies' => 2,
            'LqcFixedProperties' => 3,
            'LqcShares' => 2,
            'LqcOtherAssets' => 2
        };

        for (String className : expectedCounts.keySet()) {
            String rowsJson = LqcController.refreshRows(className, c.Id);
            List<Object> rows = (List<Object>) JSON.deserializeUntyped(rowsJson);
            System.assertEquals(
                expectedCounts.get(className),
                rows.size(),
                className + ' should return its stub rows'
            );
        }
    }

    @IsTest
    static void refreshRowsIsCaseInsensitiveOnClassName() {
        Case c = makeCase();
        // The JSON config uses lowerCamelCase names, e.g. "lqcShares".
        String rowsJson = LqcController.refreshRows('lqcShares', c.Id);
        List<Object> rows = (List<Object>) JSON.deserializeUntyped(rowsJson);
        System.assertEquals(2, rows.size());
    }

    @IsTest
    static void refreshRowsRejectsInvalidClasses() {
        Case c = makeCase();
        try {
            LqcController.refreshRows('NoSuchClass', c.Id);
            System.assert(false, 'Expected AuraHandledException for missing class');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            // Exists but does not implement ILqcPrefill.
            LqcController.refreshRows('LqcController', c.Id);
            System.assert(false, 'Expected AuraHandledException for non-conforming class');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            LqcController.refreshRows('', c.Id);
            System.assert(false, 'Expected AuraHandledException for blank class name');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void fieldKeyDerivesCamelCaseKeys() {
        System.assertEquals('accountNumber', LqcController.fieldKey('Account Number'));
        System.assertEquals('balanceAtDod', LqcController.fieldKey('Balance at DoD'));
        System.assertEquals('shareNameHolding', LqcController.fieldKey('Share Name/Holding'));
        System.assertEquals('', LqcController.fieldKey(null));
    }
}
