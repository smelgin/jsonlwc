/**
 * IIdpFindingHandler for the loan offer compliance example.
 *
 * A Compliance run writes nothing itself — it hands the differences it found
 * to a handler and lets the org decide what they mean. Here they mean the
 * signed offer letter disagrees with the approved credit decision, which is
 * something a human has to clear before money moves. So for each
 * non-compliant document this handler:
 *
 *  1. stamps the Case as Mismatched and records a readable breakdown, giving
 *     the record itself a verification state rather than leaving the finding
 *     only in the caller's Result;
 *  2. raises one high-priority Task carrying the same breakdown, so the
 *     difference lands in somebody's queue.
 *
 * Near matches (inside a value type's Compare Tolerance, e.g. a cent of
 * rounding) are listed in the breakdown for context but do not by
 * themselves trigger anything — only Mismatch findings do.
 *
 * The writes are the handler's own decision, not the engine's: the mapping
 * rules stay read-only. Contrast with the bundled IdpComplianceTaskHandler,
 * which only creates the Task — this one shows a handler that also updates
 * the record it was checking. Registered on the mapping set's
 * Finding_Handler__c (or passed as the findingHandler argument).
 */
public inherited sharing class LoanOfferMismatchHandler implements IIdpFindingHandler {
  private static final String STATUS_MISMATCHED = 'Mismatched';
  private static final String TASK_SUBJECT = 'Verify signed loan offer against the system record';
  private static final Integer NOTES_LIMIT = 32768;

  public void handle(IdpResult.RunReport report) {
    if (report == null || report.results == null) {
      return;
    }
    List<Task> tasks = new List<Task>();
    List<Case> stamps = new List<Case>();
    for (IdpResult.Result result : report.results) {
      List<IdpResult.Finding> mismatches = result.findingsWith(
        IdpResult.CODE_VALUE_MISMATCH
      );
      if (mismatches.isEmpty()) {
        continue; // this document agreed with the record
      }
      List<IdpResult.Finding> nears = result.findingsWith(
        IdpResult.CODE_VALUE_NEAR
      );

      Id caseId = firstRecordOfType(mismatches, Case.SObjectType);
      Id whatId = caseId != null
        ? caseId
        : Id.valueOf(mismatches[0].recordId);
      String narrative = narrative(report.mappingSetName, mismatches, nears);

      tasks.add(
        new Task(
          Subject = TASK_SUBJECT,
          WhatId = whatId,
          Priority = 'High',
          ActivityDate = Date.today().addDays(2),
          Description = narrative.abbreviate(32000)
        )
      );
      // Only a Case carries the verification fields this example ships; a
      // document whose mismatches are all on other objects still gets its
      // Task.
      if (caseId != null) {
        stamps.add(
          new Case(
            Id = caseId,
            Offer_Verification_Status__c = STATUS_MISMATCHED,
            Offer_Verification_Notes__c = narrative.abbreviate(NOTES_LIMIT)
          )
        );
      }
    }
    if (!tasks.isEmpty()) {
      Database.insert(tasks, AccessLevel.USER_MODE);
    }
    if (!stamps.isEmpty()) {
      Database.update(stamps, AccessLevel.USER_MODE);
    }
  }

  /**
   * Groups the differences by object so the reader sees "what the borrower
   * is" apart from "what the borrower was offered", rather than one flat
   * list of field names.
   */
  private static String narrative(
    String mappingSetName,
    List<IdpResult.Finding> mismatches,
    List<IdpResult.Finding> nears
  ) {
    Map<String, List<String>> byObject = new Map<String, List<String>>();
    for (IdpResult.Finding mismatch : mismatches) {
      describe(byObject, mismatch, '');
    }
    for (IdpResult.Finding near : nears) {
      describe(byObject, near, '  (near match — within tolerance)');
    }

    List<String> lines = new List<String>{
      'Mapping set "' +
      mappingSetName +
      '" found ' +
      mismatches.size() +
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

  private static void describe(
    Map<String, List<String>> byObject,
    IdpResult.Finding finding,
    String suffix
  ) {
    if (!byObject.containsKey(finding.objectName)) {
      byObject.put(finding.objectName, new List<String>());
    }
    byObject.get(finding.objectName)
      .add(
        '  - ' +
          finding.fieldName +
          ': document "' +
          finding.extractedValue +
          '", system "' +
          (finding.storedValue == null ? '(blank)' : finding.storedValue) +
          '"  [' +
          finding.jsonPath +
          ']' +
          suffix
      );
  }

  private static Id firstRecordOfType(
    List<IdpResult.Finding> findings,
    Schema.SObjectType targetType
  ) {
    for (IdpResult.Finding finding : findings) {
      if (String.isBlank(finding.recordId)) {
        continue;
      }
      Id recordId = Id.valueOf(finding.recordId);
      if (recordId.getSObjectType() == targetType) {
        return recordId;
      }
    }
    return null;
  }
}
