/**
 * PLACEHOLDER prefill provider for the "Insurance Policies" LQC tab.
 * Replace the stub rows with the real data source (SOQL / callout) when available.
 */
public with sharing class LqcInsurancePolicies implements ILqcPrefill {

    public List<Map<String, Object>> refresh(Id recordId) {
        // TODO v2: query the real insurance policy records related to the Case.
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        rows.add(new Map<String, Object>{
            'policyNumber' => '00000064536768661',
            'policyNumberRecordId' => recordId,
            'policyType' => 'Life',
            'status' => 'Active',
            'coverAmount' => 1500000,
            'beneficiary' => 'Estate Late'
        });
        rows.add(new Map<String, Object>{
            'policyNumber' => '00000064536768661',
            'policyNumberRecordId' => recordId,
            'policyType' => 'Funeral',
            'status' => 'Active',
            'coverAmount' => 1500000,
            'beneficiary' => 'Estate Late'
        });
        return rows;
    }
}
