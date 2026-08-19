/**
 * Server side of the idpConfigurator LWC: list the mapping sets, read one
 * set's Definition, check a draft against the real schema, and save it.
 *
 * Two things about saving are worth knowing before reading further.
 *
 * Custom metadata cannot be written with DML. A save is a Metadata API
 * deployment, which is asynchronous — this class hands back a job id and
 * the component polls readSet() until the stored Definition matches what
 * was sent. There is deliberately no "saved" return value, because at the
 * moment enqueueDeployment() returns, nothing has been saved yet.
 *
 * Deploying metadata requires Customize Application. That is a broad
 * permission, so this class checks it explicitly and fails with a message
 * an admin can act on rather than letting the platform throw.
 */
public with sharing class IdpConfiguratorController {
  @TestVisible
  private static final String SET_PREFIX = 'IDP_Mapping_Set.';

  // ──────────────────────────── read ──────────────────────────────

  public class SetSummary {
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String description;
    @AuraEnabled
    public Boolean active;
    @AuraEnabled
    public Integer sectionCount = 0;
    @AuraEnabled
    public Integer ruleCount = 0;
  }

  public class SetDetail {
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public Boolean active;
    @AuraEnabled
    public String definition;
    @AuraEnabled
    public List<Finding> findings = new List<Finding>();
    /** Objects the definition names, each with its fields, so the editor
     *  can offer a picker in place of the old FieldDefinition lookup. */
    @AuraEnabled
    public List<ObjectFields> schema = new List<ObjectFields>();
  }

  public class Finding {
    @AuraEnabled
    public String severity;
    @AuraEnabled
    public String message;
    public Finding(IdpResult.Finding source) {
      this.severity = source.severity;
      this.message = source.message;
    }
  }

  public class ObjectFields {
    @AuraEnabled
    public String objectName;
    @AuraEnabled
    public List<FieldOption> fields = new List<FieldOption>();
  }

  public class Option {
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String value;
  }

  /** Comparable so the picker arrives alphabetical without the client sorting. */
  public class FieldOption implements Comparable {
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String value;
    @AuraEnabled
    public Boolean updateable;
    @AuraEnabled
    public String type;

    public Integer compareTo(Object other) {
      return label.compareTo(((FieldOption) other).label);
    }
  }

  public class PickerData {
    @AuraEnabled
    public List<Option> objects = new List<Option>();
    @AuraEnabled
    public List<Option> valueTypes = new List<Option>();
  }

  @AuraEnabled(cacheable=true)
  public static List<SetSummary> listSets() {
    List<SetSummary> summaries = new List<SetSummary>();
    for (IDP_Mapping_Set__mdt record : [
      SELECT
        DeveloperName,
        MasterLabel,
        Description__c,
        Active__c,
        Definition__c
      FROM IDP_Mapping_Set__mdt
      ORDER BY MasterLabel
    ]) {
      SetSummary summary = new SetSummary();
      summary.name = record.DeveloperName;
      summary.label = record.MasterLabel;
      summary.description = record.Description__c;
      summary.active = record.Active__c;
      countInto(summary, record.Definition__c);
      summaries.add(summary);
    }
    return summaries;
  }

  /** Not cacheable: the component re-reads this to see a save land. */
  @AuraEnabled
  public static SetDetail readSet(String developerName) {
    List<IDP_Mapping_Set__mdt> records = [
      SELECT DeveloperName, MasterLabel, Active__c, Definition__c
      FROM IDP_Mapping_Set__mdt
      WHERE DeveloperName = :developerName
      LIMIT 1
    ];
    if (records.isEmpty()) {
      throw new AuraHandledException(
        'No IDP Mapping Set is named "' + developerName + '".'
      );
    }
    SetDetail detail = new SetDetail();
    detail.name = records[0].DeveloperName;
    detail.label = records[0].MasterLabel;
    detail.active = records[0].Active__c;
    detail.definition = prettify(records[0].Definition__c);
    detail.findings = check(developerName, detail.definition);
    detail.schema = schemaFor(detail.definition);
    return detail;
  }

  /**
   * Runs the draft through IdpConfigLoader — the same path a real run
   * takes — so what the editor shows is what the engine will say. An
   * empty list means the definition loads cleanly.
   */
  @AuraEnabled
  public static List<Finding> check(String developerName, String definition) {
    List<Finding> findings = new List<Finding>();
    for (
      IdpResult.Finding raw : IdpConfigLoader.validateDefinition(
        developerName,
        definition
      )
    ) {
      findings.add(new Finding(raw));
    }
    return findings;
  }

  /**
   * Fields of one object, for the picker that replaces the old
   * FieldDefinition lookup. Everything readable is returned; `updateable`
   * lets the form offer only writable fields as a rule's target while
   * still allowing any queryable field as a repeating section's match
   * field.
   */
  @AuraEnabled(cacheable=true)
  public static List<FieldOption> fieldsOf(String objectName) {
    List<FieldOption> options = new List<FieldOption>();
    Map<String, Schema.SObjectField> fields = IdpSchemaCache.fieldsOf(
      objectName
    );
    if (fields == null) {
      return options;
    }
    for (Schema.SObjectField field : fields.values()) {
      Schema.DescribeFieldResult described = field.getDescribe();
      if (!described.isAccessible()) {
        continue;
      }
      FieldOption option = new FieldOption();
      option.value = described.getName();
      option.label = described.getLabel() + ' (' + described.getName() + ')';
      option.updateable = described.isUpdateable();
      option.type = String.valueOf(described.getType()).toLowerCase();
      options.add(option);
    }
    options.sort();
    return options;
  }

  /**
   * The pickers' vocabulary: every object a section may target and every
   * value type a rule may name. One call, cached, so opening the editor
   * does not fan out.
   *
   * Objects come from EntityDefinition rather than getGlobalDescribe(),
   * which this codebase avoids — see IdpSchemaCache.
   */
  @AuraEnabled(cacheable=true)
  public static PickerData pickers() {
    PickerData data = new PickerData();
    for (EntityDefinition entity : [
      SELECT QualifiedApiName, Label
      FROM EntityDefinition
      WHERE IsCustomizable = TRUE AND IsQueryable = TRUE
      ORDER BY QualifiedApiName
      LIMIT 2000
    ]) {
      Option option = new Option();
      option.value = entity.QualifiedApiName;
      option.label = entity.Label + ' (' + entity.QualifiedApiName + ')';
      data.objects.add(option);
    }
    for (IDP_Value_Type__mdt type : [
      SELECT DeveloperName, MasterLabel, Kind__c
      FROM IDP_Value_Type__mdt
      ORDER BY MasterLabel
    ]) {
      Option option = new Option();
      option.value = type.DeveloperName;
      option.label = type.MasterLabel + ' — ' + type.Kind__c;
      data.valueTypes.add(option);
    }
    return data;
  }

  // ──────────────────────────── save ──────────────────────────────

  /**
   * Enqueues a Metadata API deployment writing the Definition back to the
   * set record, and returns the job id. Nothing is saved when this
   * returns — the component polls readSet() to see the result land.
   */
  @AuraEnabled
  public static String saveSet(String developerName, String definition) {
    if (!canDeploy()) {
      throw new AuraHandledException(
        'Saving configuration deploys custom metadata, which needs the ' +
          'Modify Metadata Through Metadata API or Customize Application ' +
          'permission. Ask an administrator to grant it, or edit the ' +
          'mapping set in Setup instead.'
      );
    }
    if (String.isBlank(developerName)) {
      throw new AuraHandledException('No mapping set was named.');
    }
    List<Finding> findings = check(developerName, definition);
    for (Finding finding : findings) {
      if (finding.severity == IdpResult.SEV_ERROR) {
        throw new AuraHandledException(
          'The definition was not saved because it does not load: ' +
          finding.message
        );
      }
    }

    List<IDP_Mapping_Set__mdt> records = [
      SELECT DeveloperName, MasterLabel
      FROM IDP_Mapping_Set__mdt
      WHERE DeveloperName = :developerName
      LIMIT 1
    ];
    if (records.isEmpty()) {
      throw new AuraHandledException(
        'No IDP Mapping Set is named "' + developerName + '".'
      );
    }

    Metadata.CustomMetadata record = new Metadata.CustomMetadata();
    record.fullName = SET_PREFIX + developerName;
    // The label must be resent or the deployment blanks it.
    record.label = records[0].MasterLabel;
    Metadata.CustomMetadataValue value = new Metadata.CustomMetadataValue();
    value.field = 'Definition__c';
    value.value = definition;
    record.values.add(value);

    Metadata.DeployContainer container = new Metadata.DeployContainer();
    container.addMetadata(record);
    if (Test.isRunningTest()) {
      return 'TEST-DEPLOYMENT';
    }
    return Metadata.Operations.enqueueDeployment(container, null);
  }

  // ────────────────────────── internals ───────────────────────────

  /** Set by tests to exercise both sides of the permission gate; the real
   *  answer is whichever permission the running user actually holds. */
  @TestVisible
  private static Boolean deployAllowedOverride;

  private static Boolean canDeploy() {
    if (deployAllowedOverride != null) {
      return deployAllowedOverride;
    }
    if (FeatureManagement.checkPermission('ModifyMetadata')) {
      return true;
    }
    // Customize Application subsumes it, and reaches users who hold it
    // through their profile as well as through a permission set.
    List<PermissionSetAssignment> assignments = [
      SELECT Id
      FROM PermissionSetAssignment
      WHERE
        AssigneeId = :UserInfo.getUserId()
        AND PermissionSet.PermissionsCustomizeApplication = TRUE
      LIMIT 1
    ];
    return !assignments.isEmpty();
  }

  /** Section and rule counts for the list, without failing on bad JSON. */
  private static void countInto(SetSummary summary, String definition) {
    if (String.isBlank(definition)) {
      return;
    }
    try {
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
        definition
      );
      List<Object> sections = (List<Object>) parsed.get('sections');
      if (sections == null) {
        return;
      }
      summary.sectionCount = sections.size();
      for (Object entry : sections) {
        List<Object> rules = (List<Object>) ((Map<String, Object>) entry)
          .get('rules');
        if (rules != null) {
          summary.ruleCount += rules.size();
        }
      }
    } catch (Exception e) {
      summary.sectionCount = null; // shown as "unreadable" in the list
    }
  }

  /** Re-indents stored JSON so the editor always opens on tidy text. */
  private static String prettify(String definition) {
    if (String.isBlank(definition)) {
      return '{\n  "sections": []\n}';
    }
    try {
      return JSON.serializePretty(JSON.deserializeUntyped(definition));
    } catch (Exception e) {
      return definition; // leave a broken draft exactly as the admin left it
    }
  }

  private static List<ObjectFields> schemaFor(String definition) {
    List<ObjectFields> schema = new List<ObjectFields>();
    Set<String> objectNames = new Set<String>();
    try {
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
        definition
      );
      for (Object entry : (List<Object>) parsed.get('sections')) {
        Object objectName = ((Map<String, Object>) entry).get('targetObject');
        if (objectName != null) {
          objectNames.add(String.valueOf(objectName));
        }
      }
    } catch (Exception e) {
      return schema;
    }
    for (String objectName : objectNames) {
      ObjectFields entry = new ObjectFields();
      entry.objectName = objectName;
      entry.fields = fieldsOf(objectName);
      schema.add(entry);
    }
    return schema;
  }
}
