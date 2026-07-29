@IsTest
private class LqcControllerTest {

    private static Case makeCase() {
        Case c = new Case(Subject = 'LQC Test Case', Status = 'New', Origin = 'Web');
        insert c;
        return c;
    }

    private static Account makeDeceased() {
        Account deceased = new Account(Name = 'Deceased Person');
        insert deceased;
        return deceased;
    }

    /** Case linked to the Deceased through the standard Account lookup. */
    private static Case makeCaseFor(Account deceased) {
        Case c = new Case(
            Subject = 'LQC Test Case',
            Status = 'New',
            Origin = 'Web',
            AccountId = deceased.Id
        );
        insert c;
        return c;
    }

    private static FinancialAccount makeFinancialAccount(String accountType) {
        return new FinancialAccount(
            Name = accountType + ' account',
            Type = accountType,
            FinancialAccountNumber = 'ACC-' + accountType,
            Status = 'Active'
        );
    }

    /**
     * Ownership in the standard model: an Owner-role party row whose date
     * window is currently open. IsRoleActive is read-only in the API, so the
     * dates are what both the provider and these tests rely on.
     */
    private static FinancialAccountParty makeOwnerParty(
        FinancialAccount financialAccount,
        Account owner
    ) {
        return new FinancialAccountParty(
            FinancialAccountId = financialAccount.Id,
            AccountId = owner.Id,
            Role = 'Owner',
            RoleStartDate = Date.today().addDays(-30)
        );
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
        // Only the tabs still on placeholder providers.
        Map<String, Integer> expectedCounts = new Map<String, Integer>{
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
    static void fscProvidersRequireTheDeceasedAccount() {
        Case withoutDeceased = makeCase(); // AccountId is blank
        for (String className : new List<String>{
            'LqcDebitAccounts', 'LqcCreditAccounts', 'LqcInsurancePolicies'
        }) {
            try {
                LqcController.refreshRows(className, withoutDeceased.Id);
                System.assert(false, className + ' should fail without a Deceased Account');
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }
    }

    @IsTest
    static void debitAccountsReturnAssetTypeAccountsOfTheDeceased() {
        Account deceased = makeDeceased();
        Account stranger = new Account(Name = 'Someone Else');
        insert stranger;
        Case c = makeCaseFor(deceased);

        FinancialAccount checking = makeFinancialAccount('Checking');
        FinancialAccount savings = makeFinancialAccount('Savings');
        FinancialAccount creditCard = makeFinancialAccount('Credit Card'); // liability: excluded
        FinancialAccount strangers = makeFinancialAccount('Checking');     // not the deceased
        FinancialAccount closedRole = makeFinancialAccount('Savings');     // role already ended
        insert new List<FinancialAccount>{
            checking, savings, creditCard, strangers, closedRole
        };

        FinancialAccountParty endedParty = makeOwnerParty(closedRole, deceased);
        endedParty.RoleEndDate = Date.today().addDays(-1);
        insert new List<FinancialAccountParty>{
            makeOwnerParty(checking, deceased),
            makeOwnerParty(savings, deceased),
            makeOwnerParty(creditCard, deceased),
            makeOwnerParty(strangers, stranger),
            endedParty
        };

        Test.startTest();
        String rowsJson = LqcController.refreshRows('LqcDebitAccounts', c.Id);
        Test.stopTest();

        List<Object> rows = (List<Object>) JSON.deserializeUntyped(rowsJson);
        System.assertEquals(
            2,
            rows.size(),
            'Only currently-held asset accounts of the deceased qualify'
        );
        for (Object rowObj : rows) {
            Map<String, Object> row = (Map<String, Object>) rowObj;
            System.assert(
                LqcDebitAccounts.ACCOUNT_TYPES.contains((String) row.get('accountType'))
            );
            System.assertNotEquals(null, row.get('accountNumberRecordId'));
        }
    }

    /**
     * FinancialAccountBalance rows are read-only in the API (written by the FSC
     * integration), so the balance selection logic is verified directly rather
     * than through DML.
     */
    @IsTest
    static void balanceForPicksTheFirstAvailableTypeByPreference() {
        Id accountId = LqcTestIds.next(FinancialAccount.SObjectType);
        Map<Id, Map<String, Decimal>> balances = new Map<Id, Map<String, Decimal>>{
            accountId => new Map<String, Decimal>{
                LqcFscService.BALANCE_TOTAL => 13000,
                LqcFscService.BALANCE_CURRENT_POSTED => 12500
            }
        };

        System.assertEquals(
            12500,
            LqcFscService.balanceFor(
                balances,
                accountId,
                new List<String>{
                    LqcFscService.BALANCE_CURRENT_POSTED,
                    LqcFscService.BALANCE_TOTAL
                }
            ),
            'The preferred type wins'
        );
        System.assertEquals(
            13000,
            LqcFscService.balanceFor(
                balances,
                accountId,
                new List<String>{ 'Available Credit', LqcFscService.BALANCE_TOTAL }
            ),
            'Falls through to the next available type'
        );
        System.assertEquals(
            null,
            LqcFscService.balanceFor(
                balances,
                accountId,
                new List<String>{ 'Available Credit' }
            ),
            'Null when no preferred type is present'
        );
        System.assertEquals(
            null,
            LqcFscService.balanceFor(
                balances,
                LqcTestIds.next(FinancialAccount.SObjectType),
                new List<String>{ LqcFscService.BALANCE_TOTAL }
            ),
            'Null when the account has no balance rows'
        );
    }

    @IsTest
    static void creditAccountsIncludeJointHoldingsViaParties() {
        Account deceased = makeDeceased();
        Account spouse = new Account(Name = 'Surviving Spouse');
        insert spouse;
        Case c = makeCaseFor(deceased);

        FinancialAccount ownLoan = makeFinancialAccount('Loan');
        // Outstanding amount present: used in preference to a balance row.
        ownLoan.TotalOutstandingAmount = 15000;
        // Jointly held: two Owner-role parties on the same account.
        FinancialAccount jointCard = makeFinancialAccount('Credit Card');
        insert new List<FinancialAccount>{ ownLoan, jointCard };
        insert new List<FinancialAccountParty>{
            makeOwnerParty(ownLoan, deceased),
            makeOwnerParty(jointCard, spouse),
            makeOwnerParty(jointCard, deceased)
        };

        Test.startTest();
        String rowsJson = LqcController.refreshRows('LqcCreditAccounts', c.Id);
        Test.stopTest();

        List<Object> rows = (List<Object>) JSON.deserializeUntyped(rowsJson);
        System.assertEquals(
            2,
            rows.size(),
            'Solely and jointly held liability accounts both qualify'
        );
    }

    @IsTest
    static void insurancePoliciesReturnPoliciesOfTheNamedInsured() {
        Account deceased = makeDeceased();
        Account other = new Account(Name = 'Someone Else');
        Account beneficiaryA = new Account(Name = 'Alice Beneficiary');
        Account beneficiaryB = new Account(Name = 'Bob Beneficiary');
        insert new List<Account>{ other, beneficiaryA, beneficiaryB };
        Case c = makeCaseFor(deceased);

        InsurancePolicy ownPolicy =
            new InsurancePolicy(Name = 'POL-001', NameInsuredId = deceased.Id);
        insert new List<InsurancePolicy>{
            ownPolicy,
            new InsurancePolicy(Name = 'POL-002', NameInsuredId = other.Id)
        };
        // Two beneficiaries on the same policy exercise the name join.
        insert new List<InsurancePolicyParticipant>{
            new InsurancePolicyParticipant(
                InsurancePolicyId = ownPolicy.Id,
                PrimaryParticipantAccountId = beneficiaryA.Id,
                Role = 'Beneficiary'
            ),
            new InsurancePolicyParticipant(
                InsurancePolicyId = ownPolicy.Id,
                PrimaryParticipantAccountId = beneficiaryB.Id,
                Role = 'Beneficiary'
            ),
            // Non-beneficiary role: must not appear.
            new InsurancePolicyParticipant(
                InsurancePolicyId = ownPolicy.Id,
                PrimaryParticipantAccountId = other.Id,
                Role = 'Insured'
            )
        };

        Test.startTest();
        String rowsJson = LqcController.refreshRows('LqcInsurancePolicies', c.Id);
        Test.stopTest();

        List<Object> rows = (List<Object>) JSON.deserializeUntyped(rowsJson);
        System.assertEquals(1, rows.size(), 'Only the deceased policies qualify');
        Map<String, Object> row = (Map<String, Object>) rows[0];
        System.assertEquals('POL-001', row.get('policyNumber'));
        System.assertEquals(
            'Alice Beneficiary, Bob Beneficiary',
            row.get('beneficiary'),
            'Multiple beneficiaries are joined, non-beneficiary roles excluded'
        );
    }

    @IsTest
    static void insurancePoliciesReturnNothingWhenTheDeceasedHasNone() {
        Case c = makeCaseFor(makeDeceased());

        String rowsJson = LqcController.refreshRows('LqcInsurancePolicies', c.Id);

        List<Object> rows = (List<Object>) JSON.deserializeUntyped(rowsJson);
        System.assertEquals(0, rows.size(), 'No policies means no rows and no participant query');
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
        // Leading/duplicated separators produce blank words that are skipped.
        System.assertEquals('accountNumber', LqcController.fieldKey('  Account   Number '));
        System.assertEquals('titleDeedNbr', LqcController.fieldKey('/Title-Deed  Nbr'));
    }

    @IsTest
    static void storageInstanceRejectsInvalidClasses() {
        try {
            LqcController.storageInstance('NoSuchStorageClass');
            System.assert(false, 'Expected AuraHandledException for a missing class');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            // Exists but does not implement ILqcStorage.
            LqcController.storageInstance('LqcController');
            System.assert(false, 'Expected AuraHandledException for a non-conforming class');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void saveAndLoadRethrowConfigurationErrors() {
        Case c = makeCase();
        // An unknown config record makes getConfig throw; the controller must
        // surface it unchanged rather than wrapping it.
        try {
            LqcController.getSavedResult(c.Id, 'DoesNotExist');
            System.assert(false, 'Expected AuraHandledException on load');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            LqcController.saveResult(c.Id, '{}', 'DoesNotExist');
            System.assert(false, 'Expected AuraHandledException on save');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    /** Storage strategy that always blows up, to prove errors are wrapped. */
    private class FailingStorage implements ILqcStorage {
        public String load(Id recordId) {
            throw new FailingStorageException('load exploded');
        }
        public void save(Id recordId, String payload) {
            throw new FailingStorageException('save exploded');
        }
    }

    private class FailingStorageException extends Exception {}

    @IsTest
    static void saveAndLoadWrapUnexpectedFailures() {
        Case c = makeCase();
        LqcController.storageOverride = new FailingStorage();
        try {
            try {
                LqcController.getSavedResult(c.Id, null);
                System.assert(false, 'Expected the load failure to be wrapped');
            } catch (Exception e) {
                System.assert(
                    e instanceof AuraHandledException,
                    'Storage exceptions must surface as AuraHandledException, got: ' +
                    e.getTypeName()
                );
            }
            try {
                LqcController.saveResult(c.Id, '{}', null);
                System.assert(false, 'Expected the save failure to be wrapped');
            } catch (Exception e) {
                System.assert(
                    e instanceof AuraHandledException,
                    'Storage exceptions must surface as AuraHandledException, got: ' +
                    e.getTypeName()
                );
            }
        } finally {
            LqcController.storageOverride = null;
        }
    }

    @IsTest
    static void estateCaseStorageDiscoversTheLookupAndIgnoresOtherFields() {
        // Falls back to scanning when the preferred name is absent, and still
        // lands on the same Case lookup.
        System.assertEquals(
            LqcEstateCaseStorage.caseLookup(),
            LqcEstateCaseStorage.discoverCaseLookup('Not_A_Real_Field__c'),
            'The fallback scan must find the same Case lookup'
        );

        Map<String, Schema.SObjectField> fields =
            Estate_Case__c.SObjectType.getDescribe().fields.getMap();
        System.assertEquals(
            false,
            LqcEstateCaseStorage.referencesCase(fields.get('Name')),
            'A non-reference field does not reference Case'
        );
        System.assertEquals(
            false,
            LqcEstateCaseStorage.referencesCase(fields.get('OwnerId')),
            'A reference to something other than Case does not qualify'
        );
    }

    @IsTest
    static void fscServiceHandlesEmptyInputs() {
        Account deceased = makeDeceased();
        // Owns nothing: the party query short-circuits before the account query.
        System.assertEquals(
            0,
            LqcFscService.financialAccountsForDeceased(
                deceased.Id,
                new Set<String>{ 'Checking' }
            ).size()
        );
        System.assertEquals(
            0,
            LqcFscService.balancesByAccount(new Set<Id>()).size(),
            'No accounts means no balance query'
        );
    }

    @IsTest
    static void displayNumberFallsBackToTheRecordName() {
        System.assertEquals(
            'ACC-1',
            LqcFscService.displayNumber(
                new FinancialAccount(Name = 'Cheque', FinancialAccountNumber = 'ACC-1')
            )
        );
        System.assertEquals(
            'Cheque',
            LqcFscService.displayNumber(new FinancialAccount(Name = 'Cheque')),
            'A blank account number falls back to the Name'
        );
    }
}
