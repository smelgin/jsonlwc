import { LightningElement, api } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import applyMappings from "@salesforce/apex/JsonMappingService.applyMappings";

const SAMPLE_JSON = {
  applicant: {
    name: "Jane Doe",
    email: "jane.doe@example.com",
    phone: "+27 11 555 0100"
  },
  estate: {
    description: "Estate intake captured from the scanned form."
  }
};

/**
 * Example host wiring c-file-json-review to the JSON field mapping engine.
 *
 * The review component stays storage-agnostic: it only raises `jsonsubmit`
 * with the reviewed JSON. This host owns persistence — it hands the JSON to
 * JsonMappingService.applyMappings, which resolves the records reachable
 * from the ContentDocument and, per the JSON_Field_Mapping__mdt rules of
 * the configured mapping set, either writes the values (Extraction mode)
 * or verifies them against the data model (Compliance mode), optionally
 * firing a mismatch handler class.
 */
export default class FileJsonReviewMappingDemo extends LightningElement {
  /** Id of the reviewed ContentDocument. */
  @api contentDocumentId;

  /** Mapping_Set__c of the rules to apply on save. */
  @api mappingSetName = "Estate_Intake";

  /** Run mode: Extraction (write values) or Compliance (verify values).
   *  A rule's Mode__c overrides this per field. */
  @api mode = "Extraction";

  /** Apex class implementing IComplianceMismatchHandler, invoked when a
   *  Compliance run finds mismatches (e.g. ComplianceTaskHandler). */
  @api mismatchHandler = "";

  /** CSS height passed through to c-file-json-review. */
  @api height = "600px";

  /** JSON to review. In a real pipeline this comes from the OCR/IDP
   *  response; in App Builder it is typically pasted from an example's
   *  sample/extracted.json. Blank falls back to the Estate_Intake sample. */
  @api jsonInput;

  saving = false;
  lastResult;

  get reviewJson() {
    return this.jsonInput && this.jsonInput.trim()
      ? this.jsonInput
      : JSON.stringify(SAMPLE_JSON, null, 2);
  }

  get submitLabel() {
    return this.mode === "Compliance"
      ? "Check compliance"
      : "Save to Salesforce";
  }

  handleJsonSubmit(event) {
    this.saving = true;
    this.lastResult = undefined;
    applyMappings({
      contentDocumentId: this.contentDocumentId,
      jsonString: event.detail.jsonString,
      mappingSetName: this.mappingSetName,
      mode: this.mode,
      mismatchHandler: this.mismatchHandler || null
    })
      .then((result) => {
        this.lastResult = result;
        this.dispatchEvent(
          new ShowToastEvent({
            title: this.toastTitle(result),
            message: this.toastMessage(result),
            variant: result.success
              ? result.compliant
                ? "success"
                : "warning"
              : "warning"
          })
        );
      })
      .catch((error) => {
        const message =
          (error.body && error.body.message) ||
          "The mapping could not be applied.";
        this.lastResult = { success: false, errors: [message] };
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Mapping failed",
            message,
            variant: "error"
          })
        );
      })
      .finally(() => {
        this.saving = false;
      });
  }

  toastTitle(result) {
    if (!result.success) {
      return "Completed with problems";
    }
    if (!result.compliant) {
      return "Compliance mismatches found";
    }
    return result.fieldsCompared > 0
      ? "Compliance check passed"
      : "Fields mapped";
  }

  toastMessage(result) {
    const parts = [];
    if (result.fieldsApplied > 0) {
      parts.push(
        `${result.fieldsApplied} field(s) applied to ${result.updatedRecordIds.length} record(s)`
      );
    }
    if (result.fieldsCompared > 0) {
      parts.push(
        `${result.fieldsCompared} field(s) checked, ${result.mismatches.length} mismatch(es)`
      );
    }
    return parts.join("; ") || "Nothing to process.";
  }

  get hasResult() {
    return this.lastResult !== undefined;
  }

  get hasErrors() {
    return Boolean(this.lastResult?.errors?.length);
  }

  get hasMismatches() {
    return Boolean(this.lastResult?.mismatches?.length);
  }

  get mismatchRows() {
    return (this.lastResult?.mismatches || []).map((m, index) => ({
      key: `${m.recordId}-${m.fieldName}-${index}`,
      field: `${m.objectName}.${m.fieldName}`,
      stored: m.actualValue === null ? "(blank)" : m.actualValue,
      extracted: m.extractedValue,
      jsonPath: m.jsonPath
    }));
  }

  get resultSummary() {
    if (!this.lastResult || this.lastResult.fieldsApplied === undefined) {
      return "";
    }
    return this.toastMessage(this.lastResult);
  }
}
