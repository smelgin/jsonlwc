/**
 * Sample IComplianceMismatchHandler: creates a Task on the resolved Case
 * (falling back to the first mismatched record) listing every mismatch so
 * an agent can review the differences between the document and the data
 * model. Reference for writing org-specific handlers.
 */
public inherited sharing class ComplianceTaskHandler implements IComplianceMismatchHandler {
  public void handle(JsonMappingService.ComplianceReport report) {
    Id whatId;
    for (JsonMappingService.Mismatch mismatch : report.mismatches) {
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
      report.mismatches.size() +
      ' mismatch(es) found while checking mapping set "' +
      report.mappingSetName +
      '" against the reviewed document:'
    };
    for (JsonMappingService.Mismatch mismatch : report.mismatches) {
      lines.add(
        '- ' +
          mismatch.objectName +
          '.' +
          mismatch.fieldName +
          ': stored "' +
          mismatch.actualValue +
          '" vs extracted "' +
          mismatch.extractedValue +
          '" [' +
          mismatch.jsonPath +
          ']'
      );
    }

    Database.insert(
      new Task(
        Subject = 'Review compliance mismatches',
        WhatId = whatId,
        ActivityDate = Date.today().addDays(3),
        Description = String.join(lines, '\n').abbreviate(32000)
      ),
      AccessLevel.USER_MODE
    );
  }
}
