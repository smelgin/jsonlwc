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
 *
 * @group IDP Engine
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpDmlExecutor {
  /** Records to update, merged per record across sections and documents. */
  private Map<Id, SObject> pending = new Map<Id, SObject>();

  /** Documents that staged a write to each pending record. */
  private Map<Id, List<Contribution>> contributors = new Map<Id, List<Contribution>>();

  /** Dedupe keys in staging order, so results map back to their caller. */
  private List<String> insertOrder = new List<String>();

  /** Records to create, one per dedupe key. */
  private Map<String, SObject> pendingInserts = new Map<String, SObject>();

  /** Documents that staged each record for creation. */
  private Map<String, List<Contribution>> insertContributors = new Map<String, List<Contribution>>();

  /** Lookups waiting for the Ids the insert will hand out. */
  private List<BackLink> backLinks = new List<BackLink>();

  /** A lookup on an existing record that must point at a record this run
   *  creates — resolvable only once the insert has handed out an Id. */
  private class BackLink {
    /** Key of the staged record whose Id the lookup needs. */
    public String dedupeKey;
    /** Document that staged the link, for reporting. */
    public IdpResult.Result result;
    /** Type of the record holding the lookup. */
    public Schema.SObjectType sourceType;
    /** Record holding the lookup. */
    public Id sourceId;
    /** API name of the lookup field to populate. */
    public String fieldName;
  }

  /** One document's stake in a staged record, kept so outcomes report back. */
  private class Contribution {
    /** Document that staged the write. */
    public IdpResult.Result result;
    /** True when the write came from a repeating section's row. */
    public Boolean isRow;
    /** Section the write came from. */
    public String sectionName;
    /** Row position within a repeating section. */
    public Integer rowIndex;
    /** Row match key within a repeating section. */
    public String rowKey;

    /**
     * Records which document staged a write and in what shape.
     *
     * @param result Document staging the write.
     * @param isRow True when the write belongs to a repeating section row.
     */
    public Contribution(IdpResult.Result result, Boolean isRow) {
      this.result = result;
      this.isRow = isRow;
    }
  }

  /**
   * Queues one field write into the run's single update.
   *
   * The same record and document pair contributes once, however many
   * fields it writes.
   *
   * @param result Document staging the write.
   * @param recordType Type of the record being updated.
   * @param recordId Record being updated.
   * @param fieldName API name of the field to write.
   * @param value Value to write.
   * @param isRow True when the write belongs to a repeating section row.
   */
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

  /**
   * Looks up a record already staged for creation.
   *
   * @param dedupeKey Key the record was staged under.
   * @return The staged record, or null when the key is new.
   */
  public SObject stagedInsert(String dedupeKey) {
    return pendingInserts.get(dedupeKey);
  }

  /**
   * Queues one record for creation, shared across documents.
   *
   * The first caller of a key supplies the record; later callers — another
   * document naming the same new row — get the shared instance back and
   * are recorded as contributors, mirroring how updates merge.
   *
   * @param dedupeKey Key identifying the record across documents.
   * @param candidate Record to create when the key is new.
   * @param result Document staging the creation.
   * @param isRow True when the record backs a repeating section row.
   * @param sectionName Section the record comes from.
   * @param rowIndex Row position within a repeating section.
   * @param rowKey Row match key within a repeating section.
   * @return The record staged under that key, shared or newly staged.
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
   * Queues a lookup write that waits on a record this run creates.
   *
   * This is how an anchor reached by a parent hop gets linked from its
   * source (Case.Person_Account__c → the new Account). The write joins the
   * run's single update once the insert lands; a failed insert simply
   * leaves the lookup untouched.
   *
   * @param dedupeKey Key of the staged record whose Id is needed.
   * @param result Document staging the link.
   * @param sourceType Type of the record holding the lookup.
   * @param sourceId Record holding the lookup.
   * @param fieldName API name of the lookup field to populate.
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

  /**
   * Writes everything the run staged.
   *
   * At most one partial-success insert, then one partial-success update
   * carrying any back-links the insert made resolvable.
   */
  public void flush() {
    flushInserts();
    flushUpdates();
  }

  /**
   * Creates the staged records, one object type at a time.
   *
   * Apex rejects a DML list that chunks, by contiguous SObjectType, into
   * more than 10 runs, so a run creating several object types inserts per
   * type rather than in staging order. Outcomes are reported on every
   * contributing document, and resolved Ids feed the queued back-links.
   */
  private void flushInserts() {
    if (pendingInserts.isEmpty()) {
      return;
    }
    Map<Schema.SObjectType, List<String>> keysByType = new Map<Schema.SObjectType, List<String>>();
    for (String dedupeKey : insertOrder) {
      Schema.SObjectType recordType = pendingInserts.get(dedupeKey)
        .getSObjectType();
      List<String> keys = keysByType.get(recordType);
      if (keys == null) {
        keys = new List<String>();
        keysByType.put(recordType, keys);
      }
      keys.add(dedupeKey);
    }

    Map<String, Id> createdIds = new Map<String, Id>();
    for (List<String> keysForType : keysByType.values()) {
      List<SObject> records = new List<SObject>();
      for (String dedupeKey : keysForType) {
        records.add(pendingInserts.get(dedupeKey));
      }

      SObjectAccessDecision decision = Security.stripInaccessible(
        AccessType.CREATABLE,
        records
      );
      reportRemovedInsertFields(decision.getRemovedFields());

      List<SObject> writable = decision.getRecords();
      List<Database.SaveResult> saveResults = Database.insert(writable, false);
      for (Integer i = 0; i < saveResults.size(); i++) {
        String objectName = writable[i]
          .getSObjectType()
          .getDescribe()
          .getName();
        String dedupeKey = keysForType[i];
        if (saveResults[i].isSuccess()) {
          createdIds.put(dedupeKey, saveResults[i].getId());
        }
        for (Contribution contribution : insertContributors.get(dedupeKey)) {
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

  /**
   * Updates the staged records, one object type at a time.
   *
   * Fields the running user cannot write are stripped and reported before
   * the DML, and each outcome lands on every contributing document.
   */
  private void flushUpdates() {
    if (pending.isEmpty()) {
      return;
    }
    Map<Schema.SObjectType, List<Id>> idsByType = new Map<Schema.SObjectType, List<Id>>();
    for (Id recordId : pending.keySet()) {
      Schema.SObjectType recordType = pending.get(recordId).getSObjectType();
      List<Id> ids = idsByType.get(recordType);
      if (ids == null) {
        ids = new List<Id>();
        idsByType.put(recordType, ids);
      }
      ids.add(recordId);
    }

    for (List<Id> order : idsByType.values()) {
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
    }
    pending.clear();
    contributors.clear();
  }

  /**
   * Reports fields FLS removed from the update.
   *
   * Every document that staged a write to that object is told, so a
   * silently dropped value never looks like a successful write.
   *
   * @param removedByObject Stripped field names, keyed by object name.
   */
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

  /**
   * Reports fields FLS removed from the insert.
   *
   * @param removedByObject Stripped field names, keyed by object name.
   */
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
