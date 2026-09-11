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
 *
 * @group IDP Engine
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpSchemaCache {
  /** Object describes resolved this transaction, misses cached as null. */
  private static Map<String, Schema.DescribeSObjectResult> objectDescribes = new Map<String, Schema.DescribeSObjectResult>();

  /** Field maps per object, keyed case-insensitively. */
  private static Map<String, Map<String, Schema.SObjectField>> fieldMaps = new Map<String, Map<String, Schema.SObjectField>>();

  /** Field describes per object and field, built once each. */
  private static Map<String, Schema.DescribeFieldResult> fieldDescribes = new Map<String, Schema.DescribeFieldResult>();

  /** Discovered lookup candidates per source and target object pair. */
  private static Map<String, List<String>> lookupsByPair = new Map<String, List<String>>();

  /**
   * Describes an object, caching the miss when the name is unknown.
   *
   * @param objectName API name of the object.
   * @return Object describe, or null when the object does not exist.
   */
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

  /**
   * Resolves an object name to its SObjectType token.
   *
   * @param objectName API name of the object.
   * @return SObjectType token, or null when the object does not exist.
   */
  public static Schema.SObjectType typeOf(String objectName) {
    Schema.DescribeSObjectResult described = describe(objectName);
    return described == null ? null : described.getSObjectType();
  }

  /**
   * Lists an object's fields, matched case-insensitively by name.
   *
   * @param objectName API name of the object.
   * @return Describe field map, or null when the object does not exist.
   */
  public static Map<String, Schema.SObjectField> fieldsOf(String objectName) {
    String key = keyOf(objectName);
    if (!fieldMaps.containsKey(key)) {
      Schema.DescribeSObjectResult described = describe(objectName);
      fieldMaps.put(key, described == null ? null : described.fields.getMap());
    }
    return fieldMaps.get(key);
  }

  /**
   * Resolves one field to its token.
   *
   * @param objectName API name of the object.
   * @param fieldName API name of the field.
   * @return Field token, or null when object or field does not exist.
   */
  public static Schema.SObjectField field(String objectName, String fieldName) {
    Map<String, Schema.SObjectField> fields = fieldsOf(objectName);
    return fields == null || String.isBlank(fieldName)
      ? null
      : fields.get(fieldName);
  }

  /**
   * Describes one field, once per transaction.
   *
   * Each getDescribe() builds a fresh result, so callers on the hot path —
   * once per rule per record — take the cached one.
   *
   * @param objectName API name of the object.
   * @param fieldName API name of the field.
   * @return Field describe, or null when object or field does not exist.
   */
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

  /**
   * Lists every reference field on one object that can point at another.
   *
   * Names are sorted for determinism and polymorphic lookups count when the
   * target is among their types.
   *
   * @param fromObject API name of the object holding the lookups.
   * @param targetObject API name of the object being pointed at.
   * @return Candidate field names; empty when either object is unknown or
   *         nothing joins them.
   */
  public static List<String> lookupsTo(String fromObject, String targetObject) {
    String pair = keyOf(fromObject) + '>' + keyOf(targetObject);
    if (!lookupsByPair.containsKey(pair)) {
      lookupsByPair.put(pair, discoverLookups(fromObject, targetObject));
    }
    return lookupsByPair.get(pair).clone();
  }

  /**
   * Resolves the single unambiguous lookup between two objects.
   *
   * Several candidates are an ambiguity the configuration must settle with
   * a section's `via`, never a guess made here; callers that want to
   * explain the ambiguity list the candidates with lookupsTo().
   *
   * @param fromObject API name of the object holding the lookups.
   * @param targetObject API name of the object being pointed at.
   * @return The only candidate field name, or null when there is none or
   *         more than one.
   */
  public static String findLookupTo(String fromObject, String targetObject) {
    List<String> candidates = lookupsTo(fromObject, targetObject);
    return candidates.size() == 1 ? candidates[0] : null;
  }

  /**
   * Checks that a named field can hold an Id of the target object.
   *
   * This is the validation behind a section's explicit `via`.
   *
   * @param objectName API name of the object holding the field.
   * @param fieldName API name of the candidate reference field.
   * @param targetObject API name of the object it must point at.
   * @return True when the field references the target object.
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

  /**
   * Scans an object's fields for references to the target object.
   *
   * @param fromObject API name of the object holding the lookups.
   * @param targetObject API name of the object being pointed at.
   * @return Sorted candidate field names.
   */
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

  /**
   * Tests a described field against a target type using getReferenceTo().
   *
   * @param describe Describe of the candidate field.
   * @param targetType Type the field must be able to hold.
   * @return True when the field is a reference covering that type.
   */
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

  /**
   * Normalises a name into a case-insensitive cache key.
   *
   * @param name Object or field name, possibly null.
   * @return Lowercased name, empty string when null.
   */
  private static String keyOf(String name) {
    return name == null ? '' : name.toLowerCase();
  }
}
