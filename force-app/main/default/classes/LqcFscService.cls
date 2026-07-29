/**
 * Shared FSC (Financial Services Cloud) data access for the LQC prefill
 * providers, built on the STANDARD (core) FSC data model introduced in API
 * v61.0 - FinancialAccount / FinancialAccountParty / FinancialAccountBalance -
 * not the FinServ__* managed-package objects.
 *
 * Model notes:
 *  - The Deceased is the Case's standard Account (Case.AccountId).
 *  - Client ownership is NOT a lookup on FinancialAccount; it is modeled by
 *    FinancialAccountParty rows (Role = 'Owner') whose RoleStartDate/
 *    RoleEndDate window is currently open. Joint holdings are simply
 *    additional Owner parties on the same account, so primary and joint
 *    ownership need no separate handling.
 *  - Balances are NOT fields on FinancialAccount; they are child
 *    FinancialAccountBalance rows typed by their Type picklist (e.g.
 *    'Total Balance', 'Current Posted Balance', 'Available Credit'). The
 *    latest row per type (by BalanceAsOfDate) wins.
 *  - Households/groups: accounts held by OTHER members of the deceased's
 *    group (AccountAccountRelation) are deliberately excluded - the surviving
 *    members' assets are not part of the estate. Widen the party query if the
 *    business ever asks for them.
 *  - If your org models parties against Contacts (FinancialAccountParty
 *    .ContactId) rather than Accounts, add an OR on ContactId for the
 *    deceased's primary contact.
 *
 * ------------------------------------------------------------------ FFLIB --
 * When this codebase adopts FFLIB (fflib-apex-common):
 *  - Move the three SOQL queries into fflib_SObjectSelector subclasses
 *    (CasesSelector, FinancialAccountPartiesSelector,
 *    FinancialAccountsSelector, FinancialAccountBalancesSelector); the
 *    selector owns the field list and ordering, and security moves from
 *    WITH USER_MODE to the selector's enforceCRUD/enforceFLS configuration.
 *  - Resolve selectors through the Application factory
 *    (Application.Selector.newInstance(FinancialAccount.SObjectType)) so unit
 *    tests stub them with fflib_ApexMocks and never touch the database.
 *  - This class then becomes an LqcService method behind an ILqcService
 *    interface registered in Application.Service.
 *  - There is no DML in the prefill path; persistence lives in ILqcStorage,
 *    whose save() should register records with fflib_ISObjectUnitOfWork and
 *    let the service layer commitWork() once per transaction.
 * ---------------------------------------------------------------------------
 */
public with sharing class LqcFscService {

    @TestVisible
    private static final String ROLE_OWNER = 'Owner';

    /** FinancialAccountBalance.Type values used by the providers. */
    public static final String BALANCE_TOTAL = 'Total Balance';
    public static final String BALANCE_CURRENT_POSTED = 'Current Posted Balance';

    /**
     * Returns the Account of the deceased person for this Case
     * (the standard Case.AccountId lookup).
     */
    public static Id deceasedAccountId(Id caseId) {
        List<Case> cases = [
            SELECT AccountId
            FROM Case
            WHERE Id = :caseId
            WITH USER_MODE
            LIMIT 1
        ];
        Id deceasedId = cases.isEmpty() ? null : cases[0].AccountId;
        if (deceasedId == null) {
            throw new AuraHandledException(
                'The Case has no Account (the Deceased), so Financial ' +
                'Services Cloud records cannot be retrieved.'
            );
        }
        return deceasedId;
    }

    /**
     * Financial Accounts the deceased actively owns (sole or joint - both are
     * Owner-role FinancialAccountParty rows), restricted to the given
     * FinancialAccount.Type values.
     */
    public static List<FinancialAccount> financialAccountsForDeceased(
        Id deceasedId,
        Set<String> accountTypes
    ) {
        // "Active" is expressed as the role's date window rather than
        // IsRoleActive: that field is READ-ONLY (not createable/updateable)
        // and defaults to false, so filtering on it returns nothing in an org
        // where no integration maintains it - and it cannot be seeded in Apex
        // tests. RoleStartDate/RoleEndDate are writeable and carry the same
        // meaning. If your org DOES maintain IsRoleActive, add
        // "AND IsRoleActive = TRUE" here and mock the selector in tests.
        Set<Id> financialAccountIds = new Set<Id>();
        for (FinancialAccountParty party : [
            SELECT FinancialAccountId
            FROM FinancialAccountParty
            WHERE AccountId = :deceasedId
            AND Role = :ROLE_OWNER
            AND (RoleStartDate = NULL OR RoleStartDate <= TODAY)
            AND (RoleEndDate = NULL OR RoleEndDate >= TODAY)
            WITH USER_MODE
        ]) {
            financialAccountIds.add(party.FinancialAccountId);
        }
        if (financialAccountIds.isEmpty()) {
            return new List<FinancialAccount>();
        }
        return [
            SELECT
                Id,
                Name,
                FinancialAccountNumber,
                Type,
                Status,
                OpeningDate,
                ClosingDate,
                TotalOutstandingAmount
            FROM FinancialAccount
            WHERE Id IN :financialAccountIds
            AND Type IN :accountTypes
            WITH USER_MODE
            ORDER BY Name
        ];
    }

    /**
     * Latest balance Amount per FinancialAccountBalance.Type for each account:
     * accountId -> (balance type -> amount). Ordered ascending by
     * BalanceAsOfDate so the newest row overwrites older ones.
     *
     * NOTE: FinancialAccountBalance fields (Amount, Type, FinancialAccountId)
     * are read-only in the API - these rows are written by the FSC
     * integration/Data Cloud pipeline, never by Apex. That also means Apex
     * tests cannot seed them; test balanceFor() directly instead.
     */
    public static Map<Id, Map<String, Decimal>> balancesByAccount(
        Set<Id> financialAccountIds
    ) {
        Map<Id, Map<String, Decimal>> balances = new Map<Id, Map<String, Decimal>>();
        if (financialAccountIds.isEmpty()) {
            return balances;
        }
        for (FinancialAccountBalance balance : [
            SELECT FinancialAccountId, Type, Amount
            FROM FinancialAccountBalance
            WHERE FinancialAccountId IN :financialAccountIds
            WITH USER_MODE
            ORDER BY BalanceAsOfDate ASC NULLS FIRST
        ]) {
            Map<String, Decimal> byType = balances.get(balance.FinancialAccountId);
            if (byType == null) {
                byType = new Map<String, Decimal>();
                balances.put(balance.FinancialAccountId, byType);
            }
            byType.put(balance.Type, balance.Amount);
        }
        return balances;
    }

    /**
     * Balance for display: preferred type first, falling back through the
     * remaining types, then null when the account has no balance rows yet.
     */
    public static Decimal balanceFor(
        Map<Id, Map<String, Decimal>> balances,
        Id financialAccountId,
        List<String> typesByPreference
    ) {
        Map<String, Decimal> byType = balances.get(financialAccountId);
        if (byType == null) {
            return null;
        }
        for (String balanceType : typesByPreference) {
            if (byType.get(balanceType) != null) {
                return byType.get(balanceType);
            }
        }
        return null;
    }

    /**
     * Account number for display: the FSC account number, falling back to the
     * record Name when the number was not captured.
     */
    public static String displayNumber(FinancialAccount account) {
        return String.isBlank(account.FinancialAccountNumber)
            ? account.Name
            : account.FinancialAccountNumber;
    }
}
