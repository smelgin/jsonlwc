/**
 * Prefill provider for the "Debit Accounts" LQC tab, backed by the STANDARD
 * FSC data model: FinancialAccount records the Deceased (Case.AccountId)
 * actively owns through FinancialAccountParty (Role = 'Owner'), with amounts
 * taken from the latest FinancialAccountBalance rows. See LqcFscService for
 * the ownership/balance model and the FFLIB adoption notes (selector
 * extraction, Application factory, ApexMocks).
 *
 * "Debit" = asset-side account types. Align ACCOUNT_TYPES with the
 * FinancialAccount.Type picklist values configured in your org.
 */
public with sharing class LqcDebitAccounts implements ILqcPrefill {

    @TestVisible
    private static final Set<String> ACCOUNT_TYPES = new Set<String>{
        'Checking',
        'Savings',
        'Investment'
    };

    public List<Map<String, Object>> refresh(Id recordId) {
        Id deceasedId = LqcFscService.deceasedAccountId(recordId);
        List<FinancialAccount> accounts =
            LqcFscService.financialAccountsForDeceased(deceasedId, ACCOUNT_TYPES);
        Map<Id, Map<String, Decimal>> balances =
            LqcFscService.balancesByAccount(new Map<Id, FinancialAccount>(accounts).keySet());

        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (FinancialAccount account : accounts) {
            rows.add(new Map<String, Object>{
                'accountNumber' => LqcFscService.displayNumber(account),
                'accountNumberRecordId' => account.Id,
                'accountType' => account.Type,
                'availableBalance' => LqcFscService.balanceFor(
                    balances,
                    account.Id,
                    new List<String>{
                        LqcFscService.BALANCE_CURRENT_POSTED,
                        LqcFscService.BALANCE_TOTAL
                    }
                ),
                'accountStatus' => account.Status,
                'accountName' => account.Name,
                // TODO: "Balance" is the balance at Date of Death. FSC balance
                // rows hold CURRENT amounts (BalanceAsOfDate = last sync);
                // sourcing the DoD balance needs a statement snapshot or
                // core-banking integration. Until then the latest total is
                // prefilled and the assessor corrects it.
                'balance' => LqcFscService.balanceFor(
                    balances,
                    account.Id,
                    new List<String>{
                        LqcFscService.BALANCE_TOTAL,
                        LqcFscService.BALANCE_CURRENT_POSTED
                    }
                ),
                'dateClosed' => account.ClosingDate
            });
        }
        return rows;
    }
}
