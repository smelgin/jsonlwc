/**
 * Default LQC storage strategy: keeps the payload in Estate_Case__c.LQC_Result__c
 * on the Estate Case related to the Case the component sits on.
 *
 * The Case lookup on Estate_Case__c is discovered from the schema (preferring a
 * field literally named Case__c, otherwise the single field that references
 * Case), so this class does not need to be edited if the lookup is named
 * differently. Saving creates the Estate Case when none exists yet.
 */
public with sharing class LqcEstateCaseStorage implements ILqcStorage {

    @TestVisible
    private static final String PREFERRED_LOOKUP = 'Case__c';

    private static String cachedLookup;

    public String load(Id recordId) {
        Estate_Case__c record = findByCase(recordId);
        return record == null ? null : record.LQC_Result__c;
    }

    public void save(Id recordId, String payload) {
        Estate_Case__c record = findByCase(recordId);
        if (record == null) {
            record = new Estate_Case__c();
            record.put(caseLookup(), recordId);
        }
        record.LQC_Result__c = payload;
        Database.upsert(record, AccessLevel.USER_MODE);
    }

    private Estate_Case__c findByCase(Id caseId) {
        String soql =
            'SELECT Id, LQC_Result__c FROM Estate_Case__c' +
            ' WHERE ' + caseLookup() + ' = :caseId' +
            ' ORDER BY CreatedDate ASC LIMIT 1';
        List<Estate_Case__c> rows = Database.query(soql, AccessLevel.USER_MODE);
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * API name of the Estate_Case__c field that looks up to Case.
     */
    @TestVisible
    private static String caseLookup() {
        if (cachedLookup == null) {
            cachedLookup = discoverCaseLookup(PREFERRED_LOOKUP);
        }
        return cachedLookup;
    }

    /**
     * Discovery itself, parameterised by the preferred field name so tests can
     * exercise the fallback scan without depending on how the org named it.
     */
    @TestVisible
    private static String discoverCaseLookup(String preferredName) {
        Map<String, Schema.SObjectField> fields =
            Estate_Case__c.SObjectType.getDescribe().fields.getMap();

        Schema.SObjectField preferred = fields.get(preferredName);
        if (preferred != null && referencesCase(preferred)) {
            return preferred.getDescribe().getName();
        }
        for (Schema.SObjectField field : fields.values()) {
            if (referencesCase(field)) {
                return field.getDescribe().getName();
            }
        }
        throw new AuraHandledException(
            'Estate_Case__c has no lookup to Case, so the Liquidity Calculator ' +
            'result cannot be stored. Add one (e.g. Case__c).'
        );
    }

    @TestVisible
    private static Boolean referencesCase(Schema.SObjectField field) {
        Schema.DescribeFieldResult describe = field.getDescribe();
        if (describe.getType() != Schema.DisplayType.REFERENCE) {
            return false;
        }
        for (Schema.SObjectType referenced : describe.getReferenceTo()) {
            if (referenced == Case.SObjectType) {
                return true;
            }
        }
        return false;
    }
}
