/**
 * Loads the active configuration of one mapping set: the field rules and
 * the sections they attach to. Tests inject in-memory records through the
 * testRules / testSections overrides, because custom metadata records
 * cannot be inserted in a test context.
 */
public inherited sharing class JsonMappingSelector {
  @TestVisible
  private static List<JSON_Field_Mapping__mdt> testRules;

  @TestVisible
  private static List<JSON_Mapping_Section__mdt> testSections;

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
        Anchor_Filter__c,
        Section__c
      FROM JSON_Field_Mapping__mdt
      WHERE Mapping_Set__c = :mappingSetName AND Active__c = TRUE
      ORDER BY DeveloperName
    ];
  }

  public static List<JSON_Mapping_Section__mdt> selectSections(
    String mappingSetName
  ) {
    if (testSections != null) {
      return testSections;
    }
    return [
      SELECT
        Section_Name__c,
        Section_Type__c,
        Target_Object__c,
        Row_Path__c,
        Match_Field__c,
        Match_Value__c,
        Record_Filter__c,
        Parent_Section__c
      FROM JSON_Mapping_Section__mdt
      WHERE Mapping_Set__c = :mappingSetName AND Active__c = TRUE
      ORDER BY DeveloperName
    ];
  }
}
