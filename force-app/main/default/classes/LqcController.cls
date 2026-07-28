/**
 * Server-side controller for the Liquidity Calculator (LQC) LWC.
 *
 * Responsibilities:
 *  - Serve the JSON configuration stored in Custom_Configuration__mdt.
 *  - Load / persist the calculator state through the ILqcStorage strategy named
 *    by the config's "storageClass" key (defaults to LqcEstateCaseStorage).
 *  - Dynamically instantiate ILqcPrefill implementations to refresh tab rows.
 */
public with sharing class LqcController {

    @TestVisible
    private static final String DEFAULT_CONFIG_DEV_NAME = 'DE_LQC';

    private static final String DEFAULT_STORAGE_CLASS = 'LqcEstateCaseStorage';

    /**
     * Returns the raw JSON configuration for the LQC tabs, stored in the
     * shared Custom_Configuration__mdt CMT (default record: DE_LQC).
     */
    @AuraEnabled(cacheable=true)
    public static String getConfig(String configName) {
        String devName = String.isBlank(configName) ? DEFAULT_CONFIG_DEV_NAME : configName;
        List<Custom_Configuration__mdt> configs = [
            SELECT Value__c
            FROM Custom_Configuration__mdt
            WHERE DeveloperName = :devName
            LIMIT 1
        ];
        if (configs.isEmpty() || String.isBlank(configs[0].Value__c)) {
            throw new AuraHandledException(
                'LQC configuration "' + devName + '" was not found in Custom_Configuration__mdt.'
            );
        }
        return configs[0].Value__c;
    }

    /**
     * Returns the previously saved LQC payload for the given record, or null.
     * Delegates to the ILqcStorage strategy named in the JSON config.
     */
    @AuraEnabled
    public static String getSavedResult(Id recordId, String configName) {
        try {
            return storageFor(configName).load(recordId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load saved LQC data: ' + e.getMessage());
        }
    }

    /**
     * Persists the LQC payload (rows of every tab plus the published flag)
     * through the configured ILqcStorage strategy. Used by Save and Publish.
     */
    @AuraEnabled
    public static void saveResult(Id recordId, String payload, String configName) {
        try {
            storageFor(configName).save(recordId, payload);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to save LQC data: ' + e.getMessage());
        }
    }

    /* ------------------------------------------------------------ storage */

    /**
     * Instantiates the storage strategy named by the config's "storageClass"
     * key, falling back to LqcEstateCaseStorage. The class name comes from
     * Custom Metadata (admin-controlled), never from the browser.
     */
    @TestVisible
    private static ILqcStorage storageFor(String configName) {
        String className = storageClassName(getConfig(configName));
        Type storageType = Type.forName(className);
        if (storageType == null) {
            throw new AuraHandledException('Storage class "' + className + '" was not found.');
        }
        Object instance = storageType.newInstance();
        if (!(instance instanceof ILqcStorage)) {
            throw new AuraHandledException(
                'Class "' + className + '" does not implement ILqcStorage.'
            );
        }
        return (ILqcStorage) instance;
    }

    @TestVisible
    private static String storageClassName(String configJson) {
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(configJson);
        Object configured = config.get('storageClass');
        return configured == null || String.isBlank(String.valueOf(configured))
            ? DEFAULT_STORAGE_CLASS
            : String.valueOf(configured);
    }

    /**
     * Dynamically instantiates the configured prefill class and returns its
     * rows serialized as JSON (a List<Map<String, Object>>).
     */
    @AuraEnabled
    public static String refreshRows(String className, Id recordId) {
        if (String.isBlank(className)) {
            throw new AuraHandledException('No refresh class is configured for this tab.');
        }
        Type prefillType = Type.forName(className);
        if (prefillType == null) {
            throw new AuraHandledException('Refresh class "' + className + '" was not found.');
        }
        Object instance = prefillType.newInstance();
        if (!(instance instanceof ILqcPrefill)) {
            throw new AuraHandledException(
                'Class "' + className + '" does not implement ILqcPrefill.'
            );
        }
        try {
            List<Map<String, Object>> rows = ((ILqcPrefill) instance).refresh(recordId);
            return JSON.serialize(rows == null ? new List<Map<String, Object>>() : rows);
        } catch (Exception e) {
            throw new AuraHandledException('Refresh failed: ' + e.getMessage());
        }
    }

    /**
     * Derives the camelCase row key for a column label, e.g.
     * "Account Number" -> "accountNumber", "Balance at DoD" -> "balanceAtDod".
     * Must stay in sync with fieldKey() in the lqcUtils LWC module.
     */
    public static String fieldKey(String label) {
        if (String.isBlank(label)) {
            return '';
        }
        List<String> words = label.split('[^a-zA-Z0-9]+');
        String key = '';
        for (String word : words) {
            if (String.isBlank(word)) {
                continue;
            }
            String lower = word.toLowerCase();
            key += String.isBlank(key)
                ? lower
                : lower.substring(0, 1).toUpperCase() + lower.substring(1);
        }
        return key;
    }
}
