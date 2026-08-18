/**
 * Resolves, for every document of a run at once, the records its mapping
 * rules can address — a map of object API name → anchored record per
 * document. The walk is the v1 algorithm (roots from ContentDocumentLink,
 * hub expansion, then up to three passes of parent and child hops), but
 * every step queries in bulk across documents:
 *
 *   one ContentDocumentLink query for the whole run, then one query per
 *   (object) group per pass — not one per document per object.
 *
 * A document can alternatively be seeded from a record (seedRecordId)
 * instead of a file: the record becomes the root directly and no
 * ContentDocumentLink is involved. That is how batch runs over hub
 * records work, and it makes the engine usable with no file at all.
 *
 * Anchor filters that bind {json:} values differ per document, so those
 * objects drop to per-document queries; constant filters stay grouped.
 * All queries run in USER_MODE. A record that cannot be reached is simply
 * absent from the map — the engine reports it per rule.
 */
public inherited sharing class IdpContextResolver {
  private static final String DOCUMENT_OBJECT = 'Document__c';
  private static final Integer MAX_PASSES = 3;
  private static final Integer CHILD_QUERY_LIMIT = 2000;
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

  /** What the run needs per target object. */
  public class AnchorSpec {
    public Set<String> fields = new Set<String>();
    public String filter;
  }

  /** One document's resolution state; owned by the engine's DocumentWork. */
  public class DocContext {
    public Id contentDocumentId;
    public Id seedRecordId;
    public Object jsonRoot;
    public Map<String, SObject> anchors = new Map<String, SObject>();
    public List<String> anchorOrder = new List<String>();
    /** Root candidates per object, in link order, before fetching. */
    private Map<String, List<Id>> rootCandidates = new Map<String, List<Id>>();

    private void addRootCandidate(Id recordId) {
      String entityType = recordId.getSObjectType().getDescribe().getName();
      if (SKIPPED_LINK_TYPES.contains(entityType)) {
        return;
      }
      if (!rootCandidates.containsKey(entityType)) {
        rootCandidates.put(entityType, new List<Id>());
      }
      rootCandidates.get(entityType).add(recordId);
    }

    private void anchor(String objectName, SObject record) {
      if (!anchors.containsKey(objectName)) {
        anchors.put(objectName, record);
        anchorOrder.add(objectName);
      }
    }
  }

  public static void resolveAll(
    List<DocContext> docs,
    Map<String, AnchorSpec> requests
  ) {
    if (docs.isEmpty()) {
      return;
    }
    collectRootCandidates(docs);
    fetchRoots(docs, requests);
    expandHubs(docs, requests);
    for (Integer pass = 0; pass < MAX_PASSES; pass++) {
      Boolean progressed = false;
      for (String target : requests.keySet()) {
        if (resolveParentHops(target, docs, requests)) {
          progressed = true;
        }
        if (resolveChildHops(target, docs, requests)) {
          progressed = true;
        }
      }
      if (!progressed) {
        break;
      }
    }
  }

  // ─────────────────────────── roots ──────────────────────────────

  /** ONE ContentDocumentLink query covers every file of the run. */
  private static void collectRootCandidates(List<DocContext> docs) {
    Map<Id, List<DocContext>> docsByFile = new Map<Id, List<DocContext>>();
    for (DocContext doc : docs) {
      if (doc.seedRecordId != null) {
        doc.addRootCandidate(doc.seedRecordId);
      }
      if (doc.contentDocumentId != null) {
        if (!docsByFile.containsKey(doc.contentDocumentId)) {
          docsByFile.put(doc.contentDocumentId, new List<DocContext>());
        }
        docsByFile.get(doc.contentDocumentId).add(doc);
      }
    }
    if (docsByFile.isEmpty()) {
      return;
    }
    for (ContentDocumentLink link : [
      SELECT ContentDocumentId, LinkedEntityId
      FROM ContentDocumentLink
      WHERE ContentDocumentId IN :docsByFile.keySet()
      WITH USER_MODE
      ORDER BY SystemModstamp
    ]) {
      for (DocContext doc : docsByFile.get(link.ContentDocumentId)) {
        doc.addRootCandidate(link.LinkedEntityId);
      }
    }
  }

  /** Fetches root candidates grouped per object; each document anchors
   *  the first of its candidates that survives the query (and filter). A
   *  filter binding {json:} values queries per document instead. */
  private static void fetchRoots(
    List<DocContext> docs,
    Map<String, AnchorSpec> requests
  ) {
    Set<String> objectNames = new Set<String>();
    for (DocContext doc : docs) {
      objectNames.addAll(doc.rootCandidates.keySet());
    }
    for (String objectName : objectNames) {
      AnchorSpec spec = requests.get(objectName);
      if (spec != null && IdpFilterBinder.referencesDocument(spec.filter)) {
        for (DocContext doc : docs) {
          List<Id> candidates = doc.rootCandidates.get(objectName);
          if (candidates == null) {
            continue;
          }
          for (Id candidate : candidates) {
            SObject record = queryOneForDoc(
              objectName,
              'Id',
              candidate,
              spec,
              doc.jsonRoot,
              false,
              requests
            );
            if (record != null) {
              doc.anchor(objectName, record);
              break;
            }
          }
        }
        continue;
      }
      Set<Id> ids = new Set<Id>();
      for (DocContext doc : docs) {
        List<Id> candidates = doc.rootCandidates.get(objectName);
        if (candidates != null) {
          ids.addAll(candidates);
        }
      }
      Map<Id, SObject> byId = fetchByIds(objectName, ids, requests);
      for (DocContext doc : docs) {
        List<Id> candidates = doc.rootCandidates.get(objectName);
        if (candidates == null) {
          continue;
        }
        for (Id candidate : candidates) {
          SObject record = byId.get(candidate);
          if (record != null) {
            doc.anchor(objectName, record);
            break;
          }
        }
      }
    }
  }

  // ──────────────────────── hub expansion ─────────────────────────

  /** The hub's lookups define the context graph: anchor every parent
   *  Document__c points to, so multi-hop targets stay reachable even when
   *  the intermediate object is not itself targeted. */
  private static void expandHubs(
    List<DocContext> docs,
    Map<String, AnchorSpec> requests
  ) {
    Map<String, Schema.SObjectField> hubFields = IdpSchemaCache.fieldsOf(
      DOCUMENT_OBJECT
    );
    if (hubFields == null) {
      return;
    }
    // parent object → (parent id → docs wanting it)
    Map<String, Map<Id, List<DocContext>>> wanted = new Map<String, Map<Id, List<DocContext>>>();
    for (DocContext doc : docs) {
      SObject hub = doc.anchors.get(DOCUMENT_OBJECT);
      if (hub == null) {
        continue;
      }
      for (Schema.SObjectField field : hubFields.values()) {
        Schema.DescribeFieldResult describe = field.getDescribe();
        if (
          describe.getType() != Schema.DisplayType.REFERENCE ||
          describe.getReferenceTo().isEmpty()
        ) {
          continue;
        }
        String parentType = describe.getReferenceTo()[0]
          .getDescribe()
          .getName();
        if (
          doc.anchors.containsKey(parentType) ||
          SKIPPED_PARENT_TYPES.contains(parentType)
        ) {
          continue;
        }
        Id parentId = idValue(hub, describe.getName());
        if (parentId != null) {
          want(wanted, parentType, parentId, doc);
        }
      }
    }
    fetchWanted(wanted, docs, requests);
  }

  // ─────────────────────────── passes ─────────────────────────────

  /** An anchored record holds a lookup to the target
   *  (Document__c.Case__c → Case, Case.AccountId → Account). */
  private static Boolean resolveParentHops(
    String target,
    List<DocContext> docs,
    Map<String, AnchorSpec> requests
  ) {
    Map<String, Map<Id, List<DocContext>>> wanted = new Map<String, Map<Id, List<DocContext>>>();
    for (DocContext doc : docs) {
      if (doc.anchors.containsKey(target)) {
        continue;
      }
      for (String anchored : doc.anchorOrder) {
        String lookup = IdpSchemaCache.findLookupTo(anchored, target);
        if (lookup == null) {
          continue;
        }
        Id parentId = idValue(doc.anchors.get(anchored), lookup);
        if (parentId != null) {
          want(wanted, target, parentId, doc);
          break; // first anchored object with a value wins, as in v1
        }
      }
    }
    return fetchWanted(wanted, docs, requests);
  }

  /** The target holds a lookup back to an anchored record
   *  (Estate_Case__c.Case__c = :caseId), newest record first. */
  private static Boolean resolveChildHops(
    String target,
    List<DocContext> docs,
    Map<String, AnchorSpec> requests
  ) {
    AnchorSpec spec = requests.get(target);
    Boolean progressed = false;
    // lookup field → (parent id → docs wanting the child)
    Map<String, Map<Id, List<DocContext>>> byLookup = new Map<String, Map<Id, List<DocContext>>>();
    for (DocContext doc : docs) {
      if (doc.anchors.containsKey(target)) {
        continue;
      }
      for (String anchored : doc.anchorOrder) {
        String lookup = IdpSchemaCache.findLookupTo(target, anchored);
        if (lookup == null) {
          continue;
        }
        Id parentId = doc.anchors.get(anchored).Id;
        if (spec != null && IdpFilterBinder.referencesDocument(spec.filter)) {
          // Document-bound filter — this document queries alone.
          SObject record = queryOneForDoc(
            target,
            lookup,
            parentId,
            spec,
            doc.jsonRoot,
            true,
            requests
          );
          if (record != null) {
            doc.anchor(target, record);
            progressed = true;
          }
        } else {
          if (!byLookup.containsKey(lookup)) {
            byLookup.put(lookup, new Map<Id, List<DocContext>>());
          }
          want1(byLookup.get(lookup), parentId, doc);
        }
        break; // one child-hop attempt per doc per pass, as in v1
      }
    }

    for (String lookup : byLookup.keySet()) {
      Map<Id, List<DocContext>> wantedByParent = byLookup.get(lookup);
      Map<Id, SObject> newestByParent = queryChildren(
        target,
        lookup,
        wantedByParent.keySet(),
        spec,
        requests
      );
      for (Id parentId : wantedByParent.keySet()) {
        SObject record = newestByParent.get(parentId);
        if (record == null) {
          continue;
        }
        for (DocContext doc : wantedByParent.get(parentId)) {
          if (!doc.anchors.containsKey(target)) {
            doc.anchor(target, record);
            progressed = true;
          }
        }
      }
    }
    return progressed;
  }

  // ─────────────────────────── queries ────────────────────────────

  /** Fetch of wanted (object → id → docs); returns whether any document
   *  gained an anchor. Grouped per object; a filter binding {json:}
   *  values resolves per (record, document) pair instead. */
  private static Boolean fetchWanted(
    Map<String, Map<Id, List<DocContext>>> wanted,
    List<DocContext> docs,
    Map<String, AnchorSpec> requests
  ) {
    Boolean progressed = false;
    for (String objectName : wanted.keySet()) {
      Map<Id, List<DocContext>> byId = wanted.get(objectName);
      AnchorSpec spec = requests.get(objectName);
      if (spec != null && IdpFilterBinder.referencesDocument(spec.filter)) {
        for (Id recordId : byId.keySet()) {
          for (DocContext doc : byId.get(recordId)) {
            if (doc.anchors.containsKey(objectName)) {
              continue;
            }
            SObject record = queryOneForDoc(
              objectName,
              'Id',
              recordId,
              spec,
              doc.jsonRoot,
              false,
              requests
            );
            if (record != null) {
              doc.anchor(objectName, record);
              progressed = true;
            }
          }
        }
        continue;
      }
      Map<Id, SObject> records = fetchByIds(
        objectName,
        byId.keySet(),
        requests
      );
      for (Id recordId : byId.keySet()) {
        SObject record = records.get(recordId);
        if (record == null) {
          continue;
        }
        for (DocContext doc : byId.get(recordId)) {
          if (!doc.anchors.containsKey(objectName)) {
            doc.anchor(objectName, record);
            progressed = true;
          }
        }
      }
    }
    return progressed;
  }

  /** Records by Id in one query, with the constant filter applied. */
  private static Map<Id, SObject> fetchByIds(
    String objectName,
    Set<Id> ids,
    Map<String, AnchorSpec> requests
  ) {
    Map<Id, SObject> byId = new Map<Id, SObject>();
    if (ids.isEmpty() || IdpSchemaCache.typeOf(objectName) == null) {
      return byId;
    }
    AnchorSpec spec = requests.get(objectName);
    String filter = spec == null ? null : spec.filter;

    Map<String, Object> binds = new Map<String, Object>{ 'ids' => ids };
    String whereClause = 'Id IN :ids';
    if (String.isNotBlank(filter)) {
      whereClause += ' AND (' + filter + ')';
    }
    String soql =
      'SELECT ' +
      selectList(objectName, null, requests) +
      ' FROM ' +
      objectName +
      ' WHERE ' +
      whereClause;
    try {
      for (
        SObject record : Database.queryWithBinds(
          soql,
          binds,
          AccessLevel.USER_MODE
        )
      ) {
        byId.put(record.Id, record);
      }
    } catch (Exception e) {
      // an invalid filter or FLS problem — anchors stay unresolved and the
      // engine reports the unreachable target per rule
    }
    return byId;
  }

  /** Children of many parents in one query; the newest child per parent
   *  wins, matching v1's ORDER BY CreatedDate DESC LIMIT 1. */
  private static Map<Id, SObject> queryChildren(
    String objectName,
    String lookupField,
    Set<Id> parentIds,
    AnchorSpec spec,
    Map<String, AnchorSpec> requests
  ) {
    Map<Id, SObject> newestByParent = new Map<Id, SObject>();
    if (parentIds.isEmpty() || IdpSchemaCache.typeOf(objectName) == null) {
      return newestByParent;
    }
    Map<String, Object> binds = new Map<String, Object>{
      'parentIds' => parentIds
    };
    String whereClause = lookupField + ' IN :parentIds';
    if (spec != null && String.isNotBlank(spec.filter)) {
      whereClause += ' AND (' + spec.filter + ')';
    }
    String soql =
      'SELECT ' +
      selectList(objectName, lookupField, requests) +
      ' FROM ' +
      objectName +
      ' WHERE ' +
      whereClause +
      ' ORDER BY CreatedDate DESC' +
      ' LIMIT ' +
      CHILD_QUERY_LIMIT;
    try {
      for (
        SObject record : Database.queryWithBinds(
          soql,
          binds,
          AccessLevel.USER_MODE
        )
      ) {
        Id parentId = idValue(record, lookupField);
        if (parentId != null && !newestByParent.containsKey(parentId)) {
          newestByParent.put(parentId, record); // first seen = newest
        }
      }
    } catch (Exception e) {
      // reported as unreachable by the engine
    }
    return newestByParent;
  }

  /** v1's queryFirstWhere: one record for one document, filter bound
   *  against that document's JSON. */
  private static SObject queryOneForDoc(
    String objectName,
    String whereField,
    Id value,
    AnchorSpec spec,
    Object jsonRoot,
    Boolean newestFirst,
    Map<String, AnchorSpec> requests
  ) {
    if (value == null || IdpSchemaCache.typeOf(objectName) == null) {
      return null;
    }
    Map<String, Object> binds = new Map<String, Object>{ 'value' => value };
    String whereClause = whereField + ' = :value';
    if (spec != null && String.isNotBlank(spec.filter)) {
      whereClause +=
        ' AND (' +
        IdpFilterBinder.bindFilter(spec.filter, jsonRoot, null, null, binds) +
        ')';
    }
    String soql =
      'SELECT ' +
      selectList(objectName, whereField == 'Id' ? null : whereField, requests) +
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

  /** Requested target fields (validated + accessible), the lookups later
   *  hops read, and for the hub every reference field (they drive
   *  expandHubs). */
  private static String selectList(
    String objectName,
    String extraField,
    Map<String, AnchorSpec> requests
  ) {
    Set<String> selected = new Set<String>{ 'Id' };
    Map<String, Schema.SObjectField> described = IdpSchemaCache.fieldsOf(
      objectName
    );
    if (described == null) {
      return 'Id';
    }
    AnchorSpec spec = requests.get(objectName);
    if (spec != null) {
      for (String fieldName : spec.fields) {
        Schema.SObjectField field = described.get(fieldName);
        if (field != null && field.getDescribe().isAccessible()) {
          selected.add(field.getDescribe().getName());
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
          selected.add(describe.getName());
        }
      }
    }
    for (String target : requests.keySet()) {
      if (target == objectName) {
        continue;
      }
      String lookup = IdpSchemaCache.findLookupTo(objectName, target);
      if (
        lookup != null && described.get(lookup).getDescribe().isAccessible()
      ) {
        selected.add(lookup);
      }
    }
    if (extraField != null && described.get(extraField) != null) {
      selected.add(described.get(extraField).getDescribe().getName());
    }
    return String.join(new List<String>(selected), ', ');
  }

  // ─────────────────────────── helpers ────────────────────────────

  private static void want(
    Map<String, Map<Id, List<DocContext>>> wanted,
    String objectName,
    Id recordId,
    DocContext doc
  ) {
    if (!wanted.containsKey(objectName)) {
      wanted.put(objectName, new Map<Id, List<DocContext>>());
    }
    want1(wanted.get(objectName), recordId, doc);
  }

  private static void want1(
    Map<Id, List<DocContext>> byId,
    Id recordId,
    DocContext doc
  ) {
    if (!byId.containsKey(recordId)) {
      byId.put(recordId, new List<DocContext>());
    }
    byId.get(recordId).add(doc);
  }

  private static Id idValue(SObject record, String fieldName) {
    try {
      return (Id) record.get(fieldName);
    } catch (Exception e) {
      return null; // not queried (e.g. FLS) — treat as absent
    }
  }
}
