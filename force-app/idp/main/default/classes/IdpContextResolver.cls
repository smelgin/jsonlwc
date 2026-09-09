/**
 * Resolves, for every document of a run at once, the records its mapping
 * rules can address. Two kinds of target are resolved:
 *
 *  - Implicit targets (Plan.byObject, keyed by object API name) are
 *    reached by the walk: roots from ContentDocumentLink, hub expansion,
 *    then up to three passes of parent and child hops along the ONE
 *    lookup that joins two objects. A pair of objects joined by several
 *    lookups is never guessed at — the ambiguity is noted on the document
 *    so the engine can report it — because "the Account" of a Case that
 *    has both Account__c and Person_Account__c is a configuration choice.
 *    Each document holds at most one implicit anchor per object.
 *  - Explicit targets (Plan.bySection, keyed by section name) are reached
 *    from a named source anchor through a named lookup — reachFrom / via
 *    on the section. Several sections may target the same object through
 *    different relationships; each keeps its own anchor.
 *
 * Every step queries in bulk across documents: one ContentDocumentLink
 * query for the whole run, then one query per (object or explicit
 * section) group per pass — not one per document per object.
 *
 * A document can alternatively be seeded from a record (seedRecordId)
 * instead of a file: the record becomes the root directly and no
 * ContentDocumentLink is involved. That is how batch runs over hub
 * records work, and it makes the engine usable with no file at all.
 *
 * Anchor filters that bind {json:} values differ per document, so those
 * targets drop to per-document queries; constant filters stay grouped.
 * All queries run in USER_MODE. A record that cannot be reached is simply
 * absent from the map — the engine reports it per section.
 */
public inherited sharing class IdpContextResolver {
  private static final String DEFAULT_HUB_OBJECT = 'Document__c';
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

  /** What the run needs for one target. */
  public class AnchorSpec {
    /** Target object; the map key for implicit specs, so may be left
     *  null there. */
    public String objectName;
    public Set<String> fields = new Set<String>();
    public String filter;
    /** Explicit navigation (bySection specs only): the anchor key the
     *  hop starts from — an explicit section's name, or an implicit
     *  object's API name — and the lookup it follows. */
    public String sourceKey;
    public String relationshipField;
    /** True: the target holds relationshipField pointing at the source
     *  (newest child wins). False: the source holds it. */
    public Boolean childHop = false;
  }

  /** Everything a run asks the resolver for. */
  public class Plan {
    /** Implicit targets, keyed by object API name. */
    public Map<String, AnchorSpec> byObject = new Map<String, AnchorSpec>();
    /** Explicit targets, keyed by section name. */
    public Map<String, AnchorSpec> bySection = new Map<String, AnchorSpec>();
    /** Resolution order of bySection — config order, so a chain listed
     *  source-first resolves in one pass. */
    public List<String> sectionOrder = new List<String>();
    /** The object whose lookups are all followed when it is a root
     *  (Hub_Object__c); null means Document__c. */
    public String hubObject;

    public Integer size() {
      return byObject.size() + bySection.size();
    }
  }

  /** One document's resolution state; owned by the engine's DocumentWork. */
  public class DocContext {
    public Id contentDocumentId;
    public Id seedRecordId;
    public Object jsonRoot;
    /** Implicit anchors: one record per object API name. */
    public Map<String, SObject> anchors = new Map<String, SObject>();
    public List<String> anchorOrder = new List<String>();
    /** Explicit anchors, keyed by section name. */
    public Map<String, SObject> anchorsBySection = new Map<String, SObject>();
    /** Implicit targets the walk declined to guess at: object API name →
     *  what was ambiguous. Only meaningful for objects left unanchored. */
    public Map<String, String> ambiguities = new Map<String, String>();
    /** Root candidates per object, in link order, before fetching. */
    private Map<String, List<Id>> rootCandidates = new Map<String, List<Id>>();

    /** The anchor behind a key: an explicit section's record first, else
     *  the implicit record of that object. */
    public SObject anchorFor(String key) {
      SObject record = anchorsBySection.get(key);
      return record != null ? record : anchors.get(key);
    }

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

    private void noteAmbiguity(String objectName, String reason) {
      if (!ambiguities.containsKey(objectName)) {
        ambiguities.put(objectName, reason);
      }
    }
  }

  /** Implicit targets only — the shape callers used before explicit
   *  navigation existed. */
  public static void resolveAll(
    List<DocContext> docs,
    Map<String, AnchorSpec> requests
  ) {
    Plan plan = new Plan();
    plan.byObject = requests;
    resolveAll(docs, plan);
  }

  public static void resolveAll(List<DocContext> docs, Plan plan) {
    if (docs.isEmpty()) {
      return;
    }
    for (String objectName : plan.byObject.keySet()) {
      AnchorSpec spec = plan.byObject.get(objectName);
      if (spec.objectName == null) {
        spec.objectName = objectName;
      }
    }
    // Documents that bind the same filter values to the same query (a
    // shared status code, say) share one query instead of one per
    // document — see queryOneForDoc.
    Map<String, SObject> resultCache = new Map<String, SObject>();
    collectRootCandidates(docs);
    fetchRoots(docs, plan, resultCache);
    expandHubs(docs, plan, resultCache);
    for (Integer pass = 0; pass < MAX_PASSES; pass++) {
      Boolean progressed = false;
      for (String target : plan.byObject.keySet()) {
        if (resolveParentHops(target, docs, plan, resultCache)) {
          progressed = true;
        }
        if (resolveChildHops(target, docs, plan, resultCache)) {
          progressed = true;
        }
      }
      for (String key : plan.sectionOrder) {
        if (
          resolveExplicitHop(
            key,
            plan.bySection.get(key),
            docs,
            plan,
            resultCache
          )
        ) {
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
    Plan plan,
    Map<String, SObject> resultCache
  ) {
    Set<String> objectNames = new Set<String>();
    for (DocContext doc : docs) {
      objectNames.addAll(doc.rootCandidates.keySet());
    }
    for (String objectName : objectNames) {
      AnchorSpec spec = plan.byObject.get(objectName);
      if (spec != null && IdpFilterBinder.referencesDocument(spec.filter)) {
        for (DocContext doc : docs) {
          List<Id> candidates = doc.rootCandidates.get(objectName);
          if (candidates == null) {
            continue;
          }
          for (Id candidate : candidates) {
            SObject record = queryOneForDoc(
              objectName,
              objectName,
              'Id',
              candidate,
              spec,
              doc.jsonRoot,
              false,
              plan,
              resultCache
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
      Map<Id, SObject> byId = fetchByIds(
        objectName,
        objectName,
        ids,
        spec,
        plan
      );
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
   *  the intermediate object is not itself targeted. A parent type the
   *  hub reaches through several lookups is ambiguous, not followed —
   *  a section chooses one with reachFrom: "Document__c", via: "…". */
  private static void expandHubs(
    List<DocContext> docs,
    Plan plan,
    Map<String, SObject> resultCache
  ) {
    Map<String, Schema.SObjectField> hubFields = IdpSchemaCache.fieldsOf(
      hubOf(plan)
    );
    if (hubFields == null) {
      return;
    }
    // The hub's shape does not vary per document, so it is described once
    // for the run rather than once per document per field.
    Map<String, List<String>> hubLookupsByType = new Map<String, List<String>>();
    for (Schema.SObjectField field : hubFields.values()) {
      Schema.DescribeFieldResult describe = field.getDescribe();
      if (
        describe.getType() != Schema.DisplayType.REFERENCE ||
        describe.getReferenceTo().isEmpty()
      ) {
        continue;
      }
      String parentType = describe.getReferenceTo()[0].getDescribe().getName();
      if (SKIPPED_PARENT_TYPES.contains(parentType)) {
        continue;
      }
      if (!hubLookupsByType.containsKey(parentType)) {
        hubLookupsByType.put(parentType, new List<String>());
      }
      hubLookupsByType.get(parentType).add(describe.getName());
    }
    for (List<String> lookups : hubLookupsByType.values()) {
      lookups.sort();
    }

    // parent object → (parent id → docs wanting it)
    Map<String, Map<Id, List<DocContext>>> wanted = new Map<String, Map<Id, List<DocContext>>>();
    for (DocContext doc : docs) {
      SObject hub = doc.anchors.get(hubOf(plan));
      if (hub == null) {
        continue;
      }
      for (String parentType : hubLookupsByType.keySet()) {
        if (doc.anchors.containsKey(parentType)) {
          continue;
        }
        List<String> lookups = hubLookupsByType.get(parentType);
        if (lookups.size() > 1) {
          doc.noteAmbiguity(
            parentType,
            hubOf(plan) +
              ' has several lookups to ' +
              parentType +
              ' (' +
              String.join(lookups, ', ') +
              ')'
          );
          continue;
        }
        Id parentId = idValue(hub, lookups[0]);
        if (parentId != null) {
          want(wanted, parentType, parentId, doc);
        }
      }
    }
    fetchWanted(wanted, docs, plan, resultCache);
  }

  // ─────────────────────── implicit passes ────────────────────────

  /** An anchored record holds the one lookup to the target
   *  (Document__c.Case__c → Case, Case.AccountId → Account). */
  private static Boolean resolveParentHops(
    String target,
    List<DocContext> docs,
    Plan plan,
    Map<String, SObject> resultCache
  ) {
    Map<String, Map<Id, List<DocContext>>> wanted = new Map<String, Map<Id, List<DocContext>>>();
    for (DocContext doc : docs) {
      if (doc.anchors.containsKey(target)) {
        continue;
      }
      for (String anchored : doc.anchorOrder) {
        List<String> lookups = IdpSchemaCache.lookupsTo(anchored, target);
        if (lookups.isEmpty()) {
          continue;
        }
        if (lookups.size() > 1) {
          doc.noteAmbiguity(target, severalLookups(anchored, target, lookups));
          continue;
        }
        Id parentId = idValue(doc.anchors.get(anchored), lookups[0]);
        if (parentId != null) {
          want(wanted, target, parentId, doc);
          break; // first anchored object with a value wins, as in v1
        }
      }
    }
    return fetchWanted(wanted, docs, plan, resultCache);
  }

  /** The target holds the one lookup back to an anchored record
   *  (Estate_Case__c.Case__c = :caseId), newest record first. */
  private static Boolean resolveChildHops(
    String target,
    List<DocContext> docs,
    Plan plan,
    Map<String, SObject> resultCache
  ) {
    AnchorSpec spec = plan.byObject.get(target);
    Boolean progressed = false;
    // lookup field → (parent id → docs wanting the child)
    Map<String, Map<Id, List<DocContext>>> byLookup = new Map<String, Map<Id, List<DocContext>>>();
    for (DocContext doc : docs) {
      if (doc.anchors.containsKey(target)) {
        continue;
      }
      for (String anchored : doc.anchorOrder) {
        List<String> lookups = IdpSchemaCache.lookupsTo(target, anchored);
        if (lookups.isEmpty()) {
          continue;
        }
        if (lookups.size() > 1) {
          doc.noteAmbiguity(target, severalLookups(target, anchored, lookups));
          continue;
        }
        String lookup = lookups[0];
        Id parentId = doc.anchors.get(anchored).Id;
        if (spec != null && IdpFilterBinder.referencesDocument(spec.filter)) {
          // Document-bound filter — this document queries alone.
          SObject record = queryOneForDoc(
            target,
            target,
            lookup,
            parentId,
            spec,
            doc.jsonRoot,
            true,
            plan,
            resultCache
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
        target,
        lookup,
        wantedByParent.keySet(),
        spec,
        plan
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

  // ─────────────────────── explicit hops ──────────────────────────

  /**
   * One section's declared relationship, for every document whose source
   * anchor is resolved: a parent hop reads the source's lookup and fetches
   * those Ids in one query; a child hop queries the target's children of
   * all the sources in one query, newest first. Filters that bind
   * document values query per document, as everywhere else.
   */
  private static Boolean resolveExplicitHop(
    String key,
    AnchorSpec spec,
    List<DocContext> docs,
    Plan plan,
    Map<String, SObject> resultCache
  ) {
    Boolean docBound = IdpFilterBinder.referencesDocument(spec.filter);
    Boolean progressed = false;
    // For a parent hop: target id → docs. For a child hop: source id → docs.
    Map<Id, List<DocContext>> wantedById = new Map<Id, List<DocContext>>();
    for (DocContext doc : docs) {
      if (doc.anchorsBySection.containsKey(key)) {
        continue;
      }
      SObject source = doc.anchorFor(spec.sourceKey);
      if (source == null) {
        continue;
      }
      Id wantedId = spec.childHop
        ? source.Id
        : idValue(source, spec.relationshipField);
      if (wantedId == null) {
        continue;
      }
      if (docBound) {
        SObject record = queryOneForDoc(
          key,
          spec.objectName,
          spec.childHop ? spec.relationshipField : 'Id',
          wantedId,
          spec,
          doc.jsonRoot,
          spec.childHop,
          plan,
          resultCache
        );
        if (record != null) {
          doc.anchorsBySection.put(key, record);
          progressed = true;
        }
      } else {
        want1(wantedById, wantedId, doc);
      }
    }
    if (wantedById.isEmpty()) {
      return progressed;
    }
    Map<Id, SObject> found = spec.childHop
      ? queryChildren(
          key,
          spec.objectName,
          spec.relationshipField,
          wantedById.keySet(),
          spec,
          plan
        )
      : fetchByIds(key, spec.objectName, wantedById.keySet(), spec, plan);
    for (Id wantedId : wantedById.keySet()) {
      SObject record = found.get(wantedId);
      if (record == null) {
        continue;
      }
      for (DocContext doc : wantedById.get(wantedId)) {
        if (!doc.anchorsBySection.containsKey(key)) {
          doc.anchorsBySection.put(key, record);
          progressed = true;
        }
      }
    }
    return progressed;
  }

  // ─────────────────────────── queries ────────────────────────────

  /** Fetch of wanted (object → id → docs) into the implicit map; returns
   *  whether any document gained an anchor. Grouped per object; a filter
   *  binding {json:} values resolves per (record, document) pair. */
  private static Boolean fetchWanted(
    Map<String, Map<Id, List<DocContext>>> wanted,
    List<DocContext> docs,
    Plan plan,
    Map<String, SObject> resultCache
  ) {
    Boolean progressed = false;
    for (String objectName : wanted.keySet()) {
      Map<Id, List<DocContext>> byId = wanted.get(objectName);
      AnchorSpec spec = plan.byObject.get(objectName);
      if (spec != null && IdpFilterBinder.referencesDocument(spec.filter)) {
        for (Id recordId : byId.keySet()) {
          for (DocContext doc : byId.get(recordId)) {
            if (doc.anchors.containsKey(objectName)) {
              continue;
            }
            SObject record = queryOneForDoc(
              objectName,
              objectName,
              'Id',
              recordId,
              spec,
              doc.jsonRoot,
              false,
              plan,
              resultCache
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
        objectName,
        byId.keySet(),
        spec,
        plan
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
    String key,
    String objectName,
    Set<Id> ids,
    AnchorSpec spec,
    Plan plan
  ) {
    Map<Id, SObject> byId = new Map<Id, SObject>();
    if (ids.isEmpty() || IdpSchemaCache.typeOf(objectName) == null) {
      return byId;
    }
    String filter = spec == null ? null : spec.filter;

    Map<String, Object> binds = new Map<String, Object>{ 'ids' => ids };
    String whereClause = 'Id IN :ids';
    if (String.isNotBlank(filter)) {
      whereClause += ' AND (' + filter + ')';
    }
    String soql =
      'SELECT ' +
      selectList(key, objectName, spec, null, plan) +
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
      // engine reports the unreachable target per section
    }
    return byId;
  }

  /** Children of many parents in one query; the newest child per parent
   *  wins, matching v1's ORDER BY CreatedDate DESC LIMIT 1. */
  private static Map<Id, SObject> queryChildren(
    String key,
    String objectName,
    String lookupField,
    Set<Id> parentIds,
    AnchorSpec spec,
    Plan plan
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
      selectList(key, objectName, spec, lookupField, plan) +
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
   *  against that document's JSON. Several documents commonly resolve the
   *  same filter to the same values (a shared status code, say); resultCache
   *  keys on the query text plus its bound values, so those documents reuse
   *  one query result instead of each issuing their own. */
  private static SObject queryOneForDoc(
    String key,
    String objectName,
    String whereField,
    Id value,
    AnchorSpec spec,
    Object jsonRoot,
    Boolean newestFirst,
    Plan plan,
    Map<String, SObject> resultCache
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
      selectList(
        key,
        objectName,
        spec,
        whereField == 'Id' ? null : whereField,
        plan
      ) +
      ' FROM ' +
      objectName +
      ' WHERE ' +
      whereClause +
      (newestFirst ? ' ORDER BY CreatedDate DESC' : '') +
      ' LIMIT 1';

    String cacheKey = soql + '|' + JSON.serialize(binds);
    if (resultCache.containsKey(cacheKey)) {
      return resultCache.get(cacheKey);
    }
    SObject result;
    try {
      List<SObject> rows = Database.queryWithBinds(
        soql,
        binds,
        AccessLevel.USER_MODE
      );
      result = rows.isEmpty() ? null : rows[0];
    } catch (Exception e) {
      result = null;
    }
    resultCache.put(cacheKey, result);
    return result;
  }

  /**
   * The select list for a record anchored under `key`: the fields its
   * rules need (validated + accessible), the lookups later hops read —
   * the one lookup to each implicit target, and the `via` of every
   * explicit parent hop that starts here — and for the hub every
   * reference field (they drive expandHubs).
   */
  private static String selectList(
    String key,
    String objectName,
    AnchorSpec spec,
    String extraField,
    Plan plan
  ) {
    Set<String> selected = new Set<String>{ 'Id' };
    Map<String, Schema.SObjectField> described = IdpSchemaCache.fieldsOf(
      objectName
    );
    if (described == null) {
      return 'Id';
    }
    if (spec != null) {
      for (String fieldName : spec.fields) {
        addIfAccessible(selected, described, fieldName);
      }
    }
    if (objectName.equalsIgnoreCase(hubOf(plan))) {
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
    for (String target : plan.byObject.keySet()) {
      if (target == objectName) {
        continue;
      }
      addIfAccessible(
        selected,
        described,
        IdpSchemaCache.findLookupTo(objectName, target)
      );
    }
    for (AnchorSpec explicitSpec : plan.bySection.values()) {
      if (
        !explicitSpec.childHop &&
        explicitSpec.sourceKey != null &&
        explicitSpec.sourceKey.equalsIgnoreCase(key)
      ) {
        addIfAccessible(selected, described, explicitSpec.relationshipField);
      }
    }
    if (extraField != null && described.get(extraField) != null) {
      selected.add(described.get(extraField).getDescribe().getName());
    }
    return String.join(new List<String>(selected), ', ');
  }

  // ─────────────────────────── helpers ────────────────────────────

  private static String hubOf(Plan plan) {
    return String.isBlank(plan.hubObject) ? DEFAULT_HUB_OBJECT : plan.hubObject;
  }

  private static void addIfAccessible(
    Set<String> selected,
    Map<String, Schema.SObjectField> described,
    String fieldName
  ) {
    if (fieldName == null) {
      return;
    }
    Schema.SObjectField field = described.get(fieldName);
    if (field != null && field.getDescribe().isAccessible()) {
      selected.add(field.getDescribe().getName());
    }
  }

  private static String severalLookups(
    String fromObject,
    String toObject,
    List<String> lookups
  ) {
    return fromObject +
      ' has several lookups to ' +
      toObject +
      ' (' +
      String.join(lookups, ', ') +
      ')';
  }

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
