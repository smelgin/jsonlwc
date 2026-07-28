/**
 * PLACEHOLDER prefill provider for the "Credit Accounts" LQC tab.
 * Replace the stub rows with the real data source (SOQL / callout) when available.
 */
public with sharing class LqcCreditAccounts implements ILqcPrefill {

    public List<Map<String, Object>> refresh(Id recordId) {
        // TODO v2: query the real credit account records related to the Case.
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        rows.add(new Map<String, Object>{
            'accountNumber' => '00000064536768635',
            'accountNumberRecordId' => recordId,
            'accountType' => 'Credit',
            'balanceAtDod' => 13000,
            'accountStatus' => 'Open',
            'interestOnAcct' => 150,
            'currentBalance' => 3000,
            'accountName' => 'My Credit Card'
        });
        rows.add(new Map<String, Object>{
            'accountNumber' => '00000064536768661',
            'accountNumberRecordId' => recordId,
            'accountType' => 'Credit',
            'balanceAtDod' => 47000,
            'accountStatus' => 'Open',
            'interestOnAcct' => 150,
            'currentBalance' => 3000,
            'accountName' => 'My Personal Loan'
        });
        return rows;
    }
}
