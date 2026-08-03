/**
 * IComplianceMismatchHandler for the loan offer compliance example.
 *
 * A Compliance run writes nothing itself — it hands the differences it found
 * to a handler and lets the org decide what they mean. Here they mean the
 * signed offer letter disagrees with the approved credit decision, which is
 * something a human has to clear before money moves. So this handler:
 *
 *  1. stamps the Case as Mismatched and records a readable breakdown, giving
 *     the record itself a verification state rather than leaving the finding
 *     only in the caller's Result;
 *  2. raises one high-priority Task carrying the same breakdown, so the
 *     difference lands in somebody's queue.
 *
 * The writes are the handler's own decision, not the engine's: the mapping
 * rules stay read-only. Contrast with the bundled ComplianceTaskHandler,
 * which only creates the Task — this one shows a handler that also updates
 * the record it was checking.
 *
 * Registered by passing "LoanOfferMismatchHandler" as the mismatchHandler
 * argument of JsonMappingService.applyMappings / the invocable action.
 */
public inherited sharing class LoanOfferMismatchHandler implements IComplianceMismatchHandler {
  private static final String STATUS_MISMATCHED = 'Mismatched';
  private static final String TASK_SUBJECT = 'Verify signed loan offer against the system record';
  private static final Integer NOTES_LIMIT = 32768;

  public void handle(JsonMappingService.ComplianceReport report) {
    if (
      report == null ||
      report.mismatches == null ||
      report.mismatches.isEmpty()
    ) {
      return; // nothing to report — the document agreed with the record
    }

    Id caseId = firstRecordOfType(report.mismatches, Case.SObjectType);
    Id whatId = caseId != null
      ? caseId
      : Id.valueOf(report.mismatches[0].recordId);
    String narrative = narrative(report);

    Database.insert(
      new Task(
        Subject = TASK_SUBJECT,
        WhatId = whatId,
        Priority = 'High',
        ActivityDate = Date.today().addDays(2),
        Description = narrative.abbreviate(32000)
      ),
      AccessLevel.USER_MODE
    );

    // Only a Case carries the verification fields this example ships; a run
    // whose mismatches are all on other objects still gets its Task.
    if (caseId != null) {
      Database.update(
        new Case(
          Id = caseId,
          Offer_Verification_Status__c = STATUS_MISMATCHED,
          Offer_Verification_Notes__c = narrative.abbreviate(NOTES_LIMIT)
        ),
        AccessLevel.USER_MODE
      );
    }
  }

  /**
   * Groups the differences by object so the reader sees "what the borrower
   * is" apart from "what the borrower was offered", rather than one flat
   * list of field names.
   */
  private static String narrative(JsonMappingService.ComplianceReport report) {
    Map<String, List<String>> byObject = new Map<String, List<String>>();
    for (JsonMappingService.Mismatch mismatch : report.mismatches) {
      if (!byObject.containsKey(mismatch.objectName)) {
        byObject.put(mismatch.objectName, new List<String>());
      }
      byObject.get(mismatch.objectName)
        .add(
          '  - ' +
            mismatch.fieldName +
            ': document "' +
            mismatch.extractedValue +
            '", system "' +
            (mismatch.actualValue == null ? '(blank)' : mismatch.actualValue) +
            '"  [' +
            mismatch.jsonPath +
            ']'
        );
    }

    List<String> lines = new List<String>{
      'Mapping set "' +
      report.mappingSetName +
      '" found ' +
      report.mismatches.size() +
      ' difference(s) between the signed document and the system record.',
      ''
    };
    for (String objectName : byObject.keySet()) {
      lines.add(objectName + ' (' + byObject.get(objectName).size() + ')');
      lines.addAll(byObject.get(objectName));
      lines.add('');
    }
    lines.add(
      'Do not disburse until every difference is corrected on the record or ' +
      'explained by the borrower.'
    );
    return String.join(lines, '\n');
  }

  private static Id firstRecordOfType(
    List<JsonMappingService.Mismatch> mismatches,
    Schema.SObjectType targetType
  ) {
    for (JsonMappingService.Mismatch mismatch : mismatches) {
      if (String.isBlank(mismatch.recordId)) {
        continue;
      }
      Id recordId = Id.valueOf(mismatch.recordId);
      if (recordId.getSObjectType() == targetType) {
        return recordId;
      }
    }
    return null;
  }
}
