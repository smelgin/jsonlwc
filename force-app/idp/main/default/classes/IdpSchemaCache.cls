/**
 * The engine's single door to Describe. Every lookup is cached for the
 * transaction, and nothing here calls Schema.getGlobalDescribe(), whose
 * cost is proportional to the org's whole schema; unknown object names
 * simply describe to null.
 *
 * Also owns lookup discovery (which field of A points at B), ported from
 * v1 DocumentContextResolver.findLookupTo: a field named <LocalName>__c or
 * <LocalName>Id is preferred (Case__c, AccountId), otherwise the only
 * reference field to that object; several candidates without the
 * conventional name are ambiguous and resolve to null.
 */
public inherited sharing class IdpSchemaCache {
  private static final String NO_LOOKUP = '';

  private static Map<String, Schema.DescribeSObjectResult> objectDescribes = new Map<String, Schema.DescribeSObjectResult>();
  private static Map<String, Map<String, Schema.SObjectField>> fieldMaps = new Map<String, Map<String, Schema.SObjectField>>();
  private static Map<String, String> lookupsByPair = new Map<String, String>();

  /** Describe for an object name; null when the object does not exist. */
  public static Schema.DescribeSObjectResult describe(String objectName) {
    String key = keyOf(objectName);
    if (!objectDescribes.containsKey(key)) {
      Schema.DescribeSObjectResult described = null;
      try {
        described = Schema.describeSObjects(new List<String>{ objectName })[0];
      } catch (Exception e) {
        // unknown object — cache the miss
      }
      objectDescribes.put(key, described);
    }
    return objectDescribes.get(key);
  }

  public static Schema.SObjectType typeOf(String objectName) {
    Schema.DescribeSObjectResult described = describe(objectName);
    return described == null ? null : described.getSObjectType();
  }

  /** Field map of an object; null when the object does not exist. The
   *  returned describe map matches field names case-insensitively. */
  public static Map<String, Schema.SObjectField> fieldsOf(String objectName) {
    String key = keyOf(objectName);
    if (!fieldMaps.containsKey(key)) {
      Schema.DescribeSObjectResult described = describe(objectName);
      fieldMaps.put(key, described == null ? null : described.fields.getMap());
    }
    return fieldMaps.get(key);
  }

  /** One field's token; null when object or field does not exist. */
  public static Schema.SObjectField field(String objectName, String fieldName) {
    Map<String, Schema.SObjectField> fields = fieldsOf(objectName);
    return fields == null || String.isBlank(fieldName)
      ? null
      : fields.get(fieldName);
  }

  /**
   * API name of the field on fromObject that looks up to targetObject, or
   * null when absent or ambiguous.
   */
  public static String findLookupTo(String fromObject, String targetObject) {
    String pair = keyOf(fromObject) + '>' + keyOf(targetObject);
    if (lookupsByPair.containsKey(pair)) {
      String cached = lookupsByPair.get(pair);
      return cached == NO_LOOKUP ? null : cached;
    }
    String found = discoverLookup(fromObject, targetObject);
    lookupsByPair.put(pair, found == null ? NO_LOOKUP : found);
    return found;
  }

  private static String discoverLookup(String fromObject, String targetObject) {
    Map<String, Schema.SObjectField> fields = fieldsOf(fromObject);
    Schema.SObjectType targetType = typeOf(targetObject);
    if (fields == null || targetType == null) {
      return null;
    }
    String localName = targetObject.endsWith('__c')
      ? targetObject.removeEnd('__c')
      : targetObject;
    for (
      String candidate : new List<String>{ localName + '__c', localName + 'Id' }
    ) {
      Schema.SObjectField field = fields.get(candidate);
      if (field != null && references(field.getDescribe(), targetType)) {
        return field.getDescribe().getName();
      }
    }
    String found;
    for (Schema.SObjectField field : fields.values()) {
      if (references(field.getDescribe(), targetType)) {
        if (found != null) {
          return null; // ambiguous — require the conventional name
        }
        found = field.getDescribe().getName();
      }
    }
    return found;
  }

  private static Boolean references(
    Schema.DescribeFieldResult describe,
    Schema.SObjectType targetType
  ) {
    if (describe.getType() != Schema.DisplayType.REFERENCE) {
      return false;
    }
    for (Schema.SObjectType referenced : describe.getReferenceTo()) {
      if (referenced == targetType) {
        return true;
      }
    }
    return false;
  }

  private static String keyOf(String name) {
    return name == null ? '' : name.toLowerCase();
  }
}
