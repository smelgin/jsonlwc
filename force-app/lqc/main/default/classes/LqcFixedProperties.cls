/**
 * PLACEHOLDER prefill provider for the "Fixed Properties" LQC tab (WinDeed).
 * Replace the stub rows with the real WinDeed extract when available.
 */
public with sharing class LqcFixedProperties implements ILqcPrefill {

    public List<Map<String, Object>> refresh(Id recordId) {
        // TODO v2: call the WinDeed extract service for the Case.
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        rows.add(new Map<String, Object>{
            'titleDeedNbr' => '64536768635',
            'titleDeedNbrRecordId' => recordId,
            'propertyType' => 'House',
            'propertyDesc' => 'Type Value',
            'provisionalValue' => 10563000,
            'address' => '99 4th Street Montgomery Park',
            'documentOcr' => 'Successful OCR'
        });
        rows.add(new Map<String, Object>{
            'titleDeedNbr' => '64536768635',
            'titleDeedNbrRecordId' => recordId,
            'propertyType' => 'Farm',
            'propertyDesc' => 'Type Value',
            'provisionalValue' => 563000,
            'address' => '99 4th Street Montgomery Park',
            'documentOcr' => 'Successful OCR'
        });
        rows.add(new Map<String, Object>{
            'titleDeedNbr' => '64536768635',
            'titleDeedNbrRecordId' => recordId,
            'propertyType' => 'Farm',
            'propertyDesc' => 'Type Value',
            'provisionalValue' => 1982000,
            'address' => '99 4th Street Montgomery Park',
            'documentOcr' => 'Successful OCR'
        });
        return rows;
    }
}
