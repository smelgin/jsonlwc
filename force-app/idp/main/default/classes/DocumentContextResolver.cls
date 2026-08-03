/**
 * Resolves the records reachable from a ContentDocument into a map keyed by
 * object API name, so mapping rules can address any object — standard or
 * custom — as "Case", "Account", "Opportunity", "Estate_Case__c", …
 *
 * The file is expected to be linked to the Document__c hub (the ECM mapping
 * object); records linked directly also work. From those roots the resolver
 * walks the schema toward each object the rules target:
 *
 *  1. Roots — every record the file is linked to (system link types like
 *     User are skipped). The hub's lookups are then followed so its parents
 *     are available as intermediate hops even when not targeted themselves.
 *  2. Parent hops — an anchored record has a lookup to the target
 *     (Document__c.Case__c → Case, Case.AccountId → Account).
 *  3. Child hops — the target has a lookup back to an anchored record
 *     (Estate_Case__c.Case__c = :caseId), newest record first.
 *
 * Passes repeat until every target is resolved or no progress is made.
 * Lookups are discovered dynamically: a field named <Object>__c / <Object>Id
 * is preferred, otherwise the single reference field to that object
 * (ambiguity without the conventional name resolves nothing). No object is
 * referenced at compile time, so this class deploys to any org.
 *
 * Per-object AnchorRequest.filter narrows which record anchors: an extra
 * WHERE fragment ANDed to the hop condition, with {json:path} tokens bound
 * from the reviewed JSON (values are bound, never concatenated). All anchor
 * queries use LIMIT 1; child hops order by CreatedDate DESC.
 *
 * Anchors are queried in USER_MODE with the target fields the rules need
 * (when accessible), so the service can evaluate "Only if blank" policies
 * and compliance comparisons.
 */
public inherited sharing class DocumentContextResolver {
  private static final String DOCUMENT_OBJECT = 'Document__c';
  private static final Integer MAX_PASSES = 3;
  private static final Set<String> SKIPPED_LINK_TYPES = new Set<String>{
    'User',
    'Group',
    'ContentWorkspace'
  };
  private static final Set<String> SKIPPED_PARENT_TYPES = new Set<String>{
    'User',
    'Group',
    'RecordType',
    'Profile'
  };

  /** What the service needs per target object. */
  public class AnchorRequest {
    public Set<String> fields = new Set<String>();
    public String filter;
  }

  private static Map<String, Map<String, Schema.SObjectField>> fieldCache = new Map<String, Map<String, Schema.SObjectField>>();

  public static Map<String, SObject> resolve(
    Id contentDocumentId,
    Map<String, AnchorRequest> requests,
    Object jsonRoot
  ) {
    Map<String, SObject> anchors = new Map<String, SObject>();
    List<String> anchorOrder = new List<String>();

    for (ContentDocumentLink link : [
      SELECT LinkedEntityId
      FROM ContentDocumentLink
      WHERE ContentDocumentId = :contentDocumentId
      WITH USER_MODE
    ]) {
      String entityType = link.LinkedEntityId.getSObjectType()
        .getDescribe()
        .getName();
      if (
        anchors.containsKey(entityType) ||
        SKIPPED_LINK_TYPES.contains(entityType)
      ) {
        continue;
      }
      anchor(
        entityType,
        'Id',
        link.LinkedEntityId,
        false,
        requests,
        anchors,
        anchorOrder,
        jsonRoot
      );
    }

    expandHub(requests, anchors, anchorOrder, jsonRoot);

    for (Integer pass = 0; pass < MAX_PASSES; pass++) {
      Boolean progressed = false;
      for (String target : requests.keySet()) {
        if (
          !anchors.containsKey(target) &&
          resolveTarget(target, requests, anchors, anchorOrder, jsonRoot)
        ) {
          progressed = true;
        }
      }
      if (!progressed) {
        break;
      }
    }
    return anchors;
  }

  /**
   * The hub's lookups define the context graph: anchor every parent
   * Document__c points to (skipping system objects), so multi-hop targets
   * remain reachable even when the intermediate object isn't targeted.
   */
  private static void expandHub(
    Map<String, AnchorRequest> requests,
    Map<String, SObject> anchors,
    List<String> anchorOrder,
    Object jsonRoot
  ) {
    SObject hub = anchors.get(DOCUMENT_OBJECT);
    Map<String, Schema.SObjectField> hubFields = fieldsOf(DOCUMENT_OBJECT);
    if (hub == null || hubFields == null) {
      return;
    }
    for (Schema.SObjectField field : hubFields.values()) {
      Schema.DescribeFieldResult describe = field.getDescribe();
      if (
        describe.getType() != Schema.DisplayType.REFERENCE ||
        describe.getReferenceTo().isEmpty()
      ) {
        continue;
      }
      String parentType = describe.getReferenceTo()[0].getDescribe().getName();
      if (
        anchors.containsKey(parentType) ||
        SKIPPED_PARENT_TYPES.contains(parentType)
      ) {
        continue;
      }
      Id parentId = idValue(hub, describe.getName());
      if (parentId != null) {
        anchor(
          parentType,
          'Id',
          parentId,
          false,
          requests,
          anchors,
          anchorOrder,
          jsonRoot
        );
      }
    }
  }

  /** One resolution attempt for a target: parent hops first, then child
   *  hops, from every anchored record in anchoring order. */
  private static Boolean resolveTarget(
    String target,
    Map<String, AnchorRequest> requests,
    Map<String, SObject> anchors,
    List<String> anchorOrder,
    Object jsonRoot
  ) {
    for (String anchored : anchorOrder) {
      String lookup = findLookupTo(anchored, target);
      if (lookup == null) {
        continue;
      }
      Id parentId = idValue(anchors.get(anchored), lookup);
      if (
        parentId != null &&
        anchor(
          target,
          'Id',
          parentId,
          false,
          requests,
          anchors,
          anchorOrder,
          jsonRoot
        )
      ) {
        return true;
      }
    }
    for (String anchored : anchorOrder) {
      String lookup = findLookupTo(target, anchored);
      if (
        lookup != null &&
        anchor(
          target,
          lookup,
          anchors.get(anchored).Id,
          true,
          requests,
          anchors,
          anchorOrder,
          jsonRoot
        )
      ) {
        return true;
      }
    }
    return false;
  }

  /** Queries one record and stores it as the anchor for its object. */
  private static Boolean anchor(
    String objectName,
    String whereField,
    Id value,
    Boolean newestFirst,
    Map<String, AnchorRequest> requests,
    Map<String, SObject> anchors,
    List<String> anchorOrder,
    Object jsonRoot
  ) {
    AnchorRequest request = requests.get(objectName);
    SObject record = queryFirstWhere(
      objectName,
      fieldsForQuery(objectName, requests),
      whereField,
      value,
      request == null ? null : request.filter,
      newestFirst,
      jsonRoot
    );
    if (record == null) {
      return false;
    }
    anchors.put(objectName, record);
    anchorOrder.add(objectName);
    return true;
  }

  /** Requested target fields (validated + accessible) plus the lookup
   *  fields later hops read: lookups to every other requested target, and
   *  for the hub all its reference fields (they drive expandHub). */
  private static Set<String> fieldsForQuery(
    String objectName,
    Map<String, AnchorRequest> requests
  ) {
    Set<String> fields = new Set<String>();
    Map<String, Schema.SObjectField> described = fieldsOf(objectName);
    if (described == null) {
      return fields;
    }
    if (requests.containsKey(objectName)) {
      for (String fieldName : requests.get(objectName).fields) {
        Schema.SObjectField field = described.get(fieldName);
        if (field != null && field.getDescribe().isAccessible()) {
          fields.add(fieldName);
        }
      }
    }
    if (objectName == DOCUMENT_OBJECT) {
      for (Schema.SObjectField field : described.values()) {
        Schema.DescribeFieldResult describe = field.getDescribe();
        if (
          describe.getType() == Schema.DisplayType.REFERENCE &&
          describe.isAccessible()
        ) {
          fields.add(describe.getName());
        }
      }
    }
    for (String target : requests.keySet()) {
      if (target == objectName) {
        continue;
      }
      String lookup = findLookupTo(objectName, target);
      if (
        lookup != null && described.get(lookup).getDescribe().isAccessible()
      ) {
        fields.add(lookup);
      }
    }
    return fields;
  }

  /**
   * API name of the field on fromObject that looks up to targetObject:
   * a field named <LocalName>__c or <LocalName>Id is preferred (Case__c,
   * AccountId), otherwise the only reference field to that object. Null
   * when absent or ambiguous without the conventional name.
   */
  private static String findLookupTo(String fromObject, String targetObject) {
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

  private static SObject queryFirstWhere(
    String objectName,
    Set<String> fields,
    String whereField,
    Id value,
    String filter,
    Boolean newestFirst,
    Object jsonRoot
  ) {
    if (typeOf(objectName) == null) {
      return null;
    }
    Map<String, Object> binds = new Map<String, Object>{ 'value' => value };
    String whereClause = whereField + ' = :value';
    if (String.isNotBlank(filter)) {
      whereClause += ' AND (' + bindJsonTokens(filter, jsonRoot, binds) + ')';
    }
    Set<String> selected = new Set<String>{ 'Id' };
    selected.addAll(fields);
    String soql =
      'SELECT ' +
      String.join(new List<String>(selected), ', ') +
      ' FROM ' +
      objectName +
      ' WHERE ' +
      whereClause +
      (newestFirst ? ' ORDER BY CreatedDate DESC' : '') +
      ' LIMIT 1';
    try {
      List<SObject> rows = Database.queryWithBinds(
        soql,
        binds,
        AccessLevel.USER_MODE
      );
      return rows.isEmpty() ? null : rows[0];
    } catch (Exception e) {
      return null;
    }
  }

  /**
   * Replaces {json:path} tokens in an Anchor Filter with bind variables
   * whose values come from the reviewed JSON — document values are bound,
   * never concatenated into the query. The fragment itself is
   * deployer-controlled metadata.
   */
  private static String bindJsonTokens(
    String filter,
    Object jsonRoot,
    Map<String, Object> binds
  ) {
    String processed = filter;
    Matcher matcher = Pattern.compile('\\{json:([^}]+)\\}').matcher(filter);
    Integer index = 0;
    while (matcher.find()) {
      String token = matcher.group(0);
      if (!processed.contains(token)) {
        continue; // duplicate token, already replaced
      }
      String bindName = 'jsonBind' + index;
      binds.put(bindName, JsonPathReader.read(jsonRoot, matcher.group(1)));
      processed = processed.replace(token, ':' + bindName);
      index++;
    }
    return processed;
  }

  private static Id idValue(SObject record, String fieldName) {
    try {
      return (Id) record.get(fieldName);
    } catch (Exception e) {
      return null; // not queried (e.g. FLS) — treat as absent
    }
  }

  private static Schema.SObjectType typeOf(String objectName) {
    return Schema.getGlobalDescribe().get(objectName);
  }

  private static Map<String, Schema.SObjectField> fieldsOf(String objectName) {
    if (!fieldCache.containsKey(objectName)) {
      Schema.SObjectType objectType = typeOf(objectName);
      fieldCache.put(
        objectName,
        objectType == null ? null : objectType.getDescribe().fields.getMap()
      );
    }
    return fieldCache.get(objectName);
  }
}
