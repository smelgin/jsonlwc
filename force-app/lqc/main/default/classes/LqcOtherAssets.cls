/**
 * PLACEHOLDER prefill provider for the "Other Assets" LQC tab.
 * Replace the stub rows with the real data source (SOQL / callout) when available.
 */
public with sharing class LqcOtherAssets implements ILqcPrefill {

    public List<Map<String, Object>> refresh(Id recordId) {
        // TODO: query the real "other asset" records related to the Case.
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        rows.add(new Map<String, Object>{
            'asset' => 'Toyota Hilux 2.8 GD-6',
            'type' => 'Vehicles',
            'value' => 450000,
            'status' => 'Appraised',
            'owner' => 'Deceased'
        });
        rows.add(new Map<String, Object>{
            'asset' => 'Kruger Rand collection',
            'type' => 'Cash and Investments',
            'value' => 120000,
            'status' => 'Pending valuation',
            'owner' => 'Deceased'
        });
        return rows;
    }
}
