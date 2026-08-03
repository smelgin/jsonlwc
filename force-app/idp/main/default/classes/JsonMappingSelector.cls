/**
 * Loads the active JSON_Field_Mapping__mdt rules of one mapping set.
 * Tests inject in-memory rules through the testRules override because
 * custom metadata records cannot be inserted in a test context.
 */
public inherited sharing class JsonMappingSelector {
  @TestVisible
  private static List<JSON_Field_Mapping__mdt> testRules;

  public static List<JSON_Field_Mapping__mdt> selectActive(
    String mappingSetName
  ) {
    if (testRules != null) {
      return testRules;
    }
    return [
      SELECT
        JSON_Path__c,
        Target_Object__c,
        Target_Field__c,
        Overwrite_Policy__c,
        Transform__c,
        Mode__c,
        Anchor_Filter__c
      FROM JSON_Field_Mapping__mdt
      WHERE Mapping_Set__c = :mappingSetName AND Active__c = TRUE
      ORDER BY DeveloperName
    ];
  }
}
