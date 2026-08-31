import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import apply from '@salesforce/apex/IdpMappingController.apply';
import preview from '@salesforce/apex/IdpMappingController.preview';
import {
    toPlannedRows,
    toMismatchRows,
    toFindingItems
} from 'c/idpResultFormat';

const SAMPLE_JSON = {
    applicant: {
        name: 'Jane Doe',
        email: 'jane.doe@example.com',
        phone: '+27 11 555 0100'
    },
    estate: {
        description: 'Estate intake captured from the scanned form.'
    }
};

const ERROR = 'Error';

/**
 * Example host wiring c-file-json-review to the IDP mapping engine.
 *
 * The review component stays storage-agnostic: it only raises `jsonsubmit`
 * with the reviewed JSON. This host owns persistence through
 * IdpMappingController. In Extraction mode it first calls preview() and
 * shows the planned old → new changes, so the user confirms what will
 * actually land before apply() writes it; Compliance mode calls apply()
 * directly and renders the mismatch findings.
 */
export default class FileJsonReviewMappingDemo extends LightningElement {
    /** Id of the reviewed ContentDocument. */
    @api contentDocumentId;

    /** DeveloperName of the IDP_Mapping_Set__mdt applied on save. */
    @api mappingSetName = 'Estate_Intake';

    /** Run mode: Extraction (write values) or Compliance (verify values).
     *  A rule's Mode overrides this per field. */
    @api mode = 'Extraction';

    /** Apex class implementing IIdpFindingHandler, invoked when a run finds
     *  mismatches (e.g. IdpComplianceTaskHandler). */
    @api findingHandler = '';

    /** Skip the preview step and save immediately on submit. */
    @api skipPreview = false;

    /** CSS height passed through to c-file-json-review. */
    @api height = '600px';

    /** JSON to review. In a real pipeline this comes from the OCR/IDP
     *  response; in App Builder it is typically pasted from an example's
     *  sample/extracted.json. Blank falls back to the Estate_Intake sample. */
    @api jsonInput;

    busy = false;
    lastResult;
    pendingJson;

    get reviewJson() {
        return this.jsonInput && this.jsonInput.trim()
            ? this.jsonInput
            : JSON.stringify(SAMPLE_JSON, null, 2);
    }

    get isCompliance() {
        return this.mode === 'Compliance';
    }

    get submitLabel() {
        if (this.isCompliance) {
            return 'Check compliance';
        }
        return this.skipPreview ? 'Save to Salesforce' : 'Preview changes';
    }

    handleJsonSubmit(event) {
        const jsonString = event.detail.jsonString;
        this.pendingJson = undefined;
        if (!this.isCompliance && !this.skipPreview) {
            this.run(
                preview({
                    contentDocumentId: this.contentDocumentId,
                    jsonString,
                    mappingSetName: this.mappingSetName
                }),
                (result) => {
                    this.pendingJson = jsonString;
                    return {
                        title: 'Preview ready',
                        message: `${result.plannedChanges.length} change(s) planned — nothing written yet.`,
                        variant: result.success ? 'info' : 'warning'
                    };
                }
            );
            return;
        }
        this.save(jsonString);
    }

    handleConfirmSave() {
        const jsonString = this.pendingJson;
        this.pendingJson = undefined;
        this.save(jsonString);
    }

    handleDiscardPreview() {
        this.pendingJson = undefined;
        this.lastResult = undefined;
    }

    save(jsonString) {
        this.run(
            apply({
                contentDocumentId: this.contentDocumentId,
                jsonString,
                mappingSetName: this.mappingSetName,
                mode: this.mode,
                findingHandler: this.findingHandler || null
            }),
            (result) => ({
                title: this.toastTitle(result),
                message: this.toastMessage(result),
                variant: result.success
                    ? result.compliant
                        ? 'success'
                        : 'warning'
                    : 'warning'
            })
        );
    }

    run(request, toastFor) {
        this.busy = true;
        this.lastResult = undefined;
        request
            .then((result) => {
                this.lastResult = result;
                this.dispatchEvent(new ShowToastEvent(toastFor(result)));
            })
            .catch((error) => {
                const message =
                    (error.body && error.body.message) ||
                    'The mapping could not be applied.';
                this.lastResult = {
                    success: false,
                    findings: [{ code: 'ERROR', severity: ERROR, message }],
                    plannedChanges: []
                };
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Mapping failed',
                        message,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.busy = false;
            });
    }

    toastTitle(result) {
        if (!result.success) {
            return 'Completed with problems';
        }
        if (!result.compliant) {
            return 'Compliance mismatches found';
        }
        return result.fieldsCompared > 0
            ? 'Compliance check passed'
            : 'Fields mapped';
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
                `${result.fieldsCompared} field(s) checked, ${this.mismatchFindings(result).length} mismatch(es)`
            );
        }
        return parts.join('; ') || 'Nothing to process.';
    }

    mismatchFindings(result) {
        return (result.findings || []).filter(
            (f) => f.code === 'VALUE_MISMATCH' || f.code === 'VALUE_NEAR'
        );
    }

    get hasResult() {
        return this.lastResult !== undefined;
    }

    get isAwaitingConfirm() {
        return Boolean(this.pendingJson);
    }

    get plannedRows() {
        return toPlannedRows(this.lastResult);
    }

    get hasPlannedRows() {
        return this.plannedRows.length > 0;
    }

    get mismatchRows() {
        return toMismatchRows(this.lastResult);
    }

    get hasMismatches() {
        return this.mismatchRows.length > 0;
    }

    // Mismatches stay out of this list: they are rendered as rows above.
    get problemFindings() {
        return toFindingItems(this.lastResult, { includeMismatches: false });
    }

    get hasProblemFindings() {
        return this.problemFindings.length > 0;
    }

    get resultSummary() {
        if (!this.lastResult || this.lastResult.fieldsApplied === undefined) {
            return '';
        }
        if (this.isAwaitingConfirm) {
            return `${this.plannedRows.length} change(s) will be written when you confirm.`;
        }
        return this.toastMessage(this.lastResult);
    }
}
