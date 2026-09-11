/**
 * Sample IIdpFindingHandler: one review Task per non-compliant document,
 * on the mismatched Case where there is one and otherwise on the first
 * mismatched record, listing every mismatch (and near match, labelled) so
 * an agent can review the differences. Reference implementation for
 * org-specific handlers.
 *
 * @group IDP Extensibility
 * @author Ernesto S Melgin
 */
public inherited sharing class IdpComplianceTaskHandler implements IIdpFindingHandler {
  /**
   * Raises one review Task per document that reported a value mismatch.
   *
   * @param report Run report whose results are scanned for mismatches.
   */
  public void handle(IdpResult.RunReport report) {
    List<Task> tasks = new List<Task>();
    for (IdpResult.Result result : report.results) {
      List<IdpResult.Finding> mismatches = result.findingsWith(
        IdpResult.CODE_VALUE_MISMATCH
      );
      if (mismatches.isEmpty()) {
        continue;
      }
      List<IdpResult.Finding> nears = result.findingsWith(
        IdpResult.CODE_VALUE_NEAR
      );

      Id whatId;
      for (IdpResult.Finding mismatch : mismatches) {
        if (mismatch.recordId == null) {
          continue;
        }
        Id recordId = Id.valueOf(mismatch.recordId);
        if (recordId.getSObjectType() == Case.SObjectType) {
          whatId = recordId;
          break;
        }
        if (whatId == null) {
          whatId = recordId;
        }
      }

      List<String> lines = new List<String>{
        mismatches.size() +
        ' mismatch(es) found while checking mapping set "' +
        report.mappingSetName +
        '" against the reviewed document:'
      };
      for (IdpResult.Finding mismatch : mismatches) {
        lines.add(describe(mismatch, ''));
      }
      for (IdpResult.Finding near : nears) {
        lines.add(describe(near, ' (near match)'));
      }

      tasks.add(
        new Task(
          Subject = 'Review compliance mismatches',
          WhatId = whatId,
          ActivityDate = Date.today().addDays(3),
          Description = String.join(lines, '\n').abbreviate(32000)
        )
      );
    }
    if (!tasks.isEmpty()) {
      Database.insert(tasks, AccessLevel.USER_MODE);
    }
  }

  /**
   * Renders one finding as a Task description line.
   *
   * @param finding Mismatch or near match to describe.
   * @param suffix Label appended after the compared values.
   * @return Single line naming the field, both values and the JSON Path.
   */
  private static String describe(IdpResult.Finding finding, String suffix) {
    String location = finding.rowKey == null
      ? ''
      : ' [row ' + finding.rowIndex + ', key ' + finding.rowKey + ']';
    return '- ' +
      finding.objectName +
      '.' +
      finding.fieldName +
      ': stored "' +
      finding.storedValue +
      '" vs extracted "' +
      finding.extractedValue +
      '"' +
      suffix +
      ' [' +
      finding.jsonPath +
      ']' +
      location;
  }
}
