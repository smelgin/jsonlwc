/**
 * Write planning and execution for one engine run. stage() accumulates
 * field writes for the whole run — several sections and several documents
 * writing the same record merge into one update — and stageInsert() the
 * records the run creates (opt-in, ENG-2/ENG-3), deduplicated by a caller
 * key so two documents naming the same new row share one record. flush()
 * performs at most one partial-success insert and one partial-success
 * update, both FLS-stripped, mapping every outcome back to the document
 * that staged it.
 *
 * In Preview mode nothing is flushed: the plan lives on each Result's
 * plannedChanges, which the evaluator records at staging time.
 */
public inherited sharing class IdpDmlExecutor {
  private Map<Id, SObject> pending = new Map<Id, SObject>();
  private Map<Id, List<Contribution>> contributors = new Map<Id, List<Contribution>>();

  private List<String> insertOrder = new List<String>();
  private Map<String, SObject> pendingInserts = new Map<String, SObject>();
  private Map<String, List<Contribution>> insertContributors = new Map<String, List<Contribution>>();
  private List<BackLink> backLinks = new List<BackLink>();

  /** A lookup on an existing record that must point at a record this run
   *  creates — resolvable only once the insert has handed out an Id. */
  private class BackLink {
    public String dedupeKey;
    public IdpResult.Result result;
    public Schema.SObjectType sourceType;
    public Id sourceId;
    public String fieldName;
  }

  private class Contribution {
    public IdpResult.Result result;
    public Boolean isRow;
    public String sectionName;
    public Integer rowIndex;
    public String rowKey;

    public Contribution(IdpResult.Result result, Boolean isRow) {
      this.result = result;
      this.isRow = isRow;
    }
  }

  /** Queues one field write; the same (record, doc) pair contributes once. */
  public void stage(
    IdpResult.Result result,
    Schema.SObjectType recordType,
    Id recordId,
    String fieldName,
    Object value,
    Boolean isRow
  ) {
    SObject record = pending.get(recordId);
    if (record == null) {
      record = recordType.newSObject(recordId);
      pending.put(recordId, record);
      contributors.put(recordId, new List<Contribution>());
    }
    record.put(fieldName, value);
    for (Contribution existing : contributors.get(recordId)) {
      // == on plain Apex objects without equals() is reference equality.
      if (existing.result == result) {
        return;
      }
    }
    contributors.get(recordId).add(new Contribution(result, isRow));
  }

  /** The record already staged for creation under this key, if any. */
  public SObject stagedInsert(String dedupeKey) {
    return pendingInserts.get(dedupeKey);
  }

  /**
   * Queues one record for creation. The first caller of a key supplies the
   * record; later callers (another document naming the same new row) get
   * the shared instance back and are recorded as contributors, mirroring
   * how updates merge.
   */
  public SObject stageInsert(
    String dedupeKey,
    SObject candidate,
    IdpResult.Result result,
    Boolean isRow,
    String sectionName,
    Integer rowIndex,
    String rowKey
  ) {
    SObject record = pendingInserts.get(dedupeKey);
    if (record == null) {
      record = candidate;
      insertOrder.add(dedupeKey);
      pendingInserts.put(dedupeKey, record);
      insertContributors.put(dedupeKey, new List<Contribution>());
    }
    List<Contribution> existing = insertContributors.get(dedupeKey);
    for (Contribution contribution : existing) {
      if (contribution.result == result) {
        return record;
      }
    }
    Contribution contribution = new Contribution(result, isRow);
    contribution.sectionName = sectionName;
    contribution.rowIndex = rowIndex;
    contribution.rowKey = rowKey;
    existing.add(contribution);
    return record;
  }

  /**
   * Queues "sourceId.fieldName = the Id of the record staged under
   * dedupeKey" — how a created anchor reached by a parent hop gets linked
   * from its source (Case.Person_Account__c → the new Account). The write
   * joins the run's single update after the insert lands; a failed insert
   * simply leaves the lookup untouched.
   */
  public void stageBackLink(
    String dedupeKey,
    IdpResult.Result result,
    Schema.SObjectType sourceType,
    Id sourceId,
    String fieldName
  ) {
    for (BackLink existing : backLinks) {
      if (
        existing.dedupeKey == dedupeKey &&
        existing.sourceId == sourceId &&
        existing.fieldName == fieldName
      ) {
        return;
      }
    }
    BackLink link = new BackLink();
    link.dedupeKey = dedupeKey;
    link.result = result;
    link.sourceType = sourceType;
    link.sourceId = sourceId;
    link.fieldName = fieldName;
    backLinks.add(link);
  }

  /** At most one partial-success insert, then one partial-success update
   *  (which carries any back-links the insert made resolvable). */
  public void flush() {
    flushInserts();
    flushUpdates();
  }

  private void flushInserts() {
    if (pendingInserts.isEmpty()) {
      return;
    }
    List<SObject> records = new List<SObject>();
    for (String dedupeKey : insertOrder) {
      records.add(pendingInserts.get(dedupeKey));
    }

    SObjectAccessDecision decision = Security.stripInaccessible(
      AccessType.CREATABLE,
      records
    );
    reportRemovedInsertFields(decision.getRemovedFields());

    List<SObject> writable = decision.getRecords();
    List<Database.SaveResult> saveResults = Database.insert(writable, false);
    Map<String, Id> createdIds = new Map<String, Id>();
    for (Integer i = 0; i < saveResults.size(); i++) {
      String objectName = writable[i].getSObjectType().getDescribe().getName();
      if (saveResults[i].isSuccess()) {
        createdIds.put(insertOrder[i], saveResults[i].getId());
      }
      for (Contribution contribution : insertContributors.get(insertOrder[i])) {
        if (saveResults[i].isSuccess()) {
          Id recordId = saveResults[i].getId();
          contribution.result.createdRecordIds.add(recordId);
          if (contribution.isRow) {
            contribution.result.rowsCreated++;
          }
          IdpResult.Finding created = contribution.result.add(
            contribution.isRow
              ? IdpResult.CODE_ROW_CREATED
              : IdpResult.CODE_ANCHOR_CREATED,
            IdpResult.SEV_INFO,
            'Created ' +
              objectName +
              (contribution.rowKey == null
                ? ''
                : ' for key "' + contribution.rowKey + '"') +
              ' (' +
              recordId +
              ').'
          );
          created.objectName = objectName;
          created.recordId = recordId;
          created.sectionName = contribution.sectionName;
          created.rowIndex = contribution.rowIndex;
          created.rowKey = contribution.rowKey;
        } else {
          for (Database.Error error : saveResults[i].getErrors()) {
            IdpResult.Finding finding = contribution.result.add(
              IdpResult.CODE_DML_FAILED,
              IdpResult.SEV_ERROR,
              objectName +
                (contribution.rowKey == null
                  ? ''
                  : ' for key "' + contribution.rowKey + '"') +
                ' could not be created: ' +
                error.getMessage()
            );
            finding.objectName = objectName;
            finding.sectionName = contribution.sectionName;
            finding.rowIndex = contribution.rowIndex;
            finding.rowKey = contribution.rowKey;
          }
        }
      }
    }
    for (BackLink link : backLinks) {
      Id createdId = createdIds.get(link.dedupeKey);
      if (createdId != null) {
        stage(
          link.result,
          link.sourceType,
          link.sourceId,
          link.fieldName,
          createdId,
          false
        );
      }
    }
    backLinks.clear();
    insertOrder.clear();
    pendingInserts.clear();
    insertContributors.clear();
  }

  private void flushUpdates() {
    if (pending.isEmpty()) {
      return;
    }
    List<Id> order = new List<Id>(pending.keySet());
    List<SObject> records = new List<SObject>();
    for (Id recordId : order) {
      records.add(pending.get(recordId));
    }

    SObjectAccessDecision decision = Security.stripInaccessible(
      AccessType.UPDATABLE,
      records
    );
    reportRemovedFields(decision.getRemovedFields());

    List<SObject> writable = decision.getRecords();
    List<Database.SaveResult> saveResults = Database.update(writable, false);
    for (Integer i = 0; i < saveResults.size(); i++) {
      Id recordId = writable[i].Id;
      List<Contribution> contributions = contributors.get(recordId);
      if (contributions == null) {
        continue;
      }
      if (saveResults[i].isSuccess()) {
        for (Contribution contribution : contributions) {
          if (!contribution.result.updatedRecordIds.contains(recordId)) {
            contribution.result.updatedRecordIds.add(recordId);
          }
          if (contribution.isRow) {
            contribution.result.rowsUpdated++;
          }
        }
      } else {
        String objectName = writable[i]
          .getSObjectType()
          .getDescribe()
          .getName();
        for (Database.Error error : saveResults[i].getErrors()) {
          for (Contribution contribution : contributions) {
            IdpResult.Finding finding = contribution.result.add(
              IdpResult.CODE_DML_FAILED,
              IdpResult.SEV_ERROR,
              objectName + ': ' + error.getMessage()
            );
            finding.objectName = objectName;
            finding.recordId = recordId;
          }
        }
      }
    }
    pending.clear();
    contributors.clear();
  }

  /** Fields FLS stripped away: reported on every document that staged a
   *  write to that object. */
  private void reportRemovedFields(Map<String, Set<String>> removedByObject) {
    for (String objectName : removedByObject.keySet()) {
      String fields = String.join(
        new List<String>(removedByObject.get(objectName)),
        ', '
      );
      for (Id recordId : pending.keySet()) {
        if (
          pending.get(recordId).getSObjectType().getDescribe().getName() !=
          objectName
        ) {
          continue;
        }
        for (Contribution contribution : contributors.get(recordId)) {
          IdpResult.Finding finding = contribution.result.add(
            IdpResult.CODE_FLS_BLOCKED,
            IdpResult.SEV_ERROR,
            'No update access to ' + objectName + ' field(s): ' + fields + '.'
          );
          finding.objectName = objectName;
          finding.recordId = recordId;
        }
      }
    }
  }

  /** Same, for the create side. */
  private void reportRemovedInsertFields(
    Map<String, Set<String>> removedByObject
  ) {
    for (String objectName : removedByObject.keySet()) {
      String fields = String.join(
        new List<String>(removedByObject.get(objectName)),
        ', '
      );
      for (String dedupeKey : insertOrder) {
        if (
          pendingInserts.get(dedupeKey)
            .getSObjectType()
            .getDescribe()
            .getName() != objectName
        ) {
          continue;
        }
        for (Contribution contribution : insertContributors.get(dedupeKey)) {
          IdpResult.Finding finding = contribution.result.add(
            IdpResult.CODE_FLS_BLOCKED,
            IdpResult.SEV_ERROR,
            'No create access to ' + objectName + ' field(s): ' + fields + '.'
          );
          finding.objectName = objectName;
          finding.sectionName = contribution.sectionName;
          finding.rowKey = contribution.rowKey;
        }
      }
    }
  }
}
