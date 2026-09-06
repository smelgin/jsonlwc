/**
 * The engine's single door to Describe. Every lookup is cached for the
 * transaction, and nothing here calls Schema.getGlobalDescribe(), whose
 * cost is proportional to the org's whole schema; unknown object names
 * simply describe to null.
 *
 * Also owns relationship discovery (which fields of A point at B). The
 * answer comes from Describe alone — getReferenceTo() — never from a
 * field's name: lookupsTo() lists every candidate, findLookupTo() returns
 * the one candidate when there is exactly one and null otherwise, so an
 * object with several lookups to the same target (Asset has three to
 * Account) is reported as ambiguous rather than guessed at. A section
 * that needs one of several chooses it explicitly with its `via` key.
 */
public inherited sharing class IdpSchemaCache {
  private static Map<String, Schema.DescribeSObjectResult> objectDescribes = new Map<String, Schema.DescribeSObjectResult>();
  private static Map<String, Map<String, Schema.SObjectField>> fieldMaps = new Map<String, Map<String, Schema.SObjectField>>();
  private static Map<String, Schema.DescribeFieldResult> fieldDescribes = new Map<String, Schema.DescribeFieldResult>();
  private static Map<String, List<String>> lookupsByPair = new Map<String, List<String>>();

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

  /** One field's describe; null when object or field does not exist. Each
   *  getDescribe() builds a fresh result, so callers on the hot path (once
   *  per rule per record) take the cached one. */
  public static Schema.DescribeFieldResult fieldDescribe(
    String objectName,
    String fieldName
  ) {
    String key = keyOf(objectName) + '.' + keyOf(fieldName);
    if (!fieldDescribes.containsKey(key)) {
      Schema.SObjectField token = field(objectName, fieldName);
      fieldDescribes.put(key, token == null ? null : token.getDescribe());
    }
    return fieldDescribes.get(key);
  }

  // ─────────────────────── relationship discovery ───────────────────

  /**
   * API names of every reference field on fromObject that can point at
   * targetObject, sorted for determinism. Empty when either object is
   * unknown or nothing joins them. Polymorphic lookups count when the
   * target is among their types.
   */
  public static List<String> lookupsTo(String fromObject, String targetObject) {
    String pair = keyOf(fromObject) + '>' + keyOf(targetObject);
    if (!lookupsByPair.containsKey(pair)) {
      lookupsByPair.put(pair, discoverLookups(fromObject, targetObject));
    }
    return lookupsByPair.get(pair).clone();
  }

  /**
   * The one field on fromObject that looks up to targetObject, or null
   * when there is none — or more than one. Several candidates are an
   * ambiguity the configuration must settle (a section's `via`), never a
   * guess made here; callers that want to explain the ambiguity list the
   * candidates with lookupsTo().
   */
  public static String findLookupTo(String fromObject, String targetObject) {
    List<String> candidates = lookupsTo(fromObject, targetObject);
    return candidates.size() == 1 ? candidates[0] : null;
  }

  /**
   * Whether objectName.fieldName is a reference field that can hold an Id
   * of targetObject — the check behind a section's explicit `via`.
   */
  public static Boolean references(
    String objectName,
    String fieldName,
    String targetObject
  ) {
    Schema.DescribeFieldResult described = fieldDescribe(objectName, fieldName);
    Schema.SObjectType targetType = typeOf(targetObject);
    return described != null &&
      targetType != null &&
      references(described, targetType);
  }

  private static List<String> discoverLookups(
    String fromObject,
    String targetObject
  ) {
    List<String> found = new List<String>();
    Map<String, Schema.SObjectField> fields = fieldsOf(fromObject);
    Schema.SObjectType targetType = typeOf(targetObject);
    if (fields == null || targetType == null) {
      return found;
    }
    for (Schema.SObjectField field : fields.values()) {
      Schema.DescribeFieldResult described = field.getDescribe();
      if (references(described, targetType)) {
        found.add(described.getName());
      }
    }
    found.sort();
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
