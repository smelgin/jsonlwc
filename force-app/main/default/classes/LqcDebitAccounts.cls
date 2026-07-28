/**
 * PLACEHOLDER prefill provider for the "Debit Accounts" LQC tab.
 * Replace the stub rows with the real data source (SOQL / callout) when available.
 */
public with sharing class LqcDebitAccounts implements ILqcPrefill {

    public List<Map<String, Object>> refresh(Id recordId) {
        // TODO v2: query the real debit account records related to the Case.
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        rows.add(new Map<String, Object>{
            'accountNumber' => '00000064536768635',
            // PLACEHOLDER: links back to the Case itself until real records exist.
            'accountNumberRecordId' => recordId,
            'accountType' => 'Debit',
            'availableBalance' => 13000,
            'accountStatus' => 'Open',
            'accountName' => 'My Debit Account',
            'balance' => 3000,
            'dateClosed' => null
        });
        rows.add(new Map<String, Object>{
            'accountNumber' => '00000064536768661',
            'accountNumberRecordId' => recordId,
            'accountType' => 'Debit',
            'availableBalance' => 47000,
            'accountStatus' => 'Open',
            'accountName' => 'My Savings Account',
            'balance' => 3000,
            'dateClosed' => null
        });
        return rows;
    }
}
