/**
 * Write planning and execution for one engine run. stage() accumulates
 * field writes for the whole run — several sections and several documents
 * writing the same record merge into one update — and flush() performs a
 * single partial-success DML, FLS-stripped, mapping every outcome back to
 * the document that staged it.
 *
 * In Preview mode nothing is flushed: the plan lives on each Result's
 * plannedChanges, which the evaluator records at staging time.
 */
public inherited sharing class IdpDmlExecutor {
  private Map<Id, SObject> pending = new Map<Id, SObject>();
  private Map<Id, List<Contribution>> contributors = new Map<Id, List<Contribution>>();

  private class Contribution {
    public IdpResult.Result result;
    public Boolean isRow;

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

  /** One partial-success update for everything staged. */
  public void flush() {
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
}
