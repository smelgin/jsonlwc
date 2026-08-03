/**
 * Prefill provider for the "Credit Accounts" LQC tab, backed by the STANDARD
 * FSC data model: liability-side FinancialAccount records the Deceased
 * (Case.AccountId) actively owns through FinancialAccountParty
 * (Role = 'Owner'). See LqcFscService for the ownership/balance model and the
 * FFLIB adoption notes (selector extraction, Application factory, ApexMocks).
 *
 * "Credit" = liability account types. Align ACCOUNT_TYPES with the
 * FinancialAccount.Type picklist values configured in your org ('Automotive
 * Loan' / 'Automotive Lease' are the two values guaranteed by the core
 * picklist; the banking values come with FSC setup).
 */
public with sharing class LqcCreditAccounts implements ILqcPrefill {

    @TestVisible
    private static final Set<String> ACCOUNT_TYPES = new Set<String>{
        'Credit Card',
        'Loan',
        'Mortgage',
        'Automotive Loan',
        'Automotive Lease'
    };

    public List<Map<String, Object>> refresh(Id recordId) {
        Id deceasedId = LqcFscService.deceasedAccountId(recordId);
        List<FinancialAccount> accounts =
            LqcFscService.financialAccountsForDeceased(deceasedId, ACCOUNT_TYPES);
        Map<Id, Map<String, Decimal>> balances =
            LqcFscService.balancesByAccount(new Map<Id, FinancialAccount>(accounts).keySet());

        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (FinancialAccount account : accounts) {
            // Liability exposure: prefer the account's TotalOutstandingAmount,
            // then fall back to the latest Total Balance row.
            Decimal outstanding = account.TotalOutstandingAmount != null
                ? account.TotalOutstandingAmount
                : LqcFscService.balanceFor(
                      balances,
                      account.Id,
                      new List<String>{
                          LqcFscService.BALANCE_TOTAL,
                          LqcFscService.BALANCE_CURRENT_POSTED
                      }
                  );
            rows.add(new Map<String, Object>{
                'accountNumber' => LqcFscService.displayNumber(account),
                'accountNumberRecordId' => account.Id,
                'accountType' => account.Type,
                // TODO: FSC holds only CURRENT amounts; the balance at Date of
                // Death needs a statement snapshot / core-banking integration.
                // Prefilled with the current outstanding amount meanwhile.
                'balanceAtDod' => outstanding,
                'accountStatus' => account.Status,
                // TODO: "Interest on Account" (interest accrued since DoD) has
                // no FSC standard field; InterestPaidYearToDate is the nearest
                // standard proxy but measures something different. Map your
                // org's custom field or integration result here; left blank
                // for manual capture meanwhile.
                'interestOnAcct' => null,
                'currentBalance' => outstanding,
                'accountName' => account.Name
            });
        }
        return rows;
    }
}
