/**
 * PLACEHOLDER prefill provider for the "Shares" LQC tab.
 * Replace the stub rows with the real data source (SOQL / callout) when available.
 */
public with sharing class LqcShares implements ILqcPrefill {

    public List<Map<String, Object>> refresh(Id recordId) {
        // TODO v2: query the real shareholding records related to the Case.
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        rows.add(new Map<String, Object>{
            'shareNameHolding' => '00000064536768661',
            'shareNameHoldingRecordId' => recordId,
            'numberOfShares' => 100,
            'currentValue' => 1500000,
            'status' => 'Active'
        });
        rows.add(new Map<String, Object>{
            'shareNameHolding' => '00000064536768661',
            'shareNameHoldingRecordId' => recordId,
            'numberOfShares' => 200,
            'currentValue' => 2500000,
            'status' => 'Sold'
        });
        return rows;
    }
}
