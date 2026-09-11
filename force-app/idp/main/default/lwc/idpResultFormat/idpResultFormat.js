/**
 * Turns an IdpResult.Result into rows a template can iterate — shared by
 * every component that renders an engine result (c-file-json-review's
 * preview panel, c-file-json-review-mapping-demo's result card), so the
 * presentation of a result lives in exactly one place and cannot drift.
 *
 * Pure functions over plain data: no Apex, no DOM, no component state.
 *
 * @module idpResultFormat
 */

/** Finding codes that describe a compared value rather than a problem. */
const MISMATCH_CODES = ['VALUE_MISMATCH', 'VALUE_NEAR'];

/**
 * Renders a stored value for display, so an empty field reads as blank
 * rather than as the word "null".
 *
 * @param {*} value Value as the engine reported it.
 * @returns {*} The value, or the blank placeholder.
 */
function displayValue(value) {
    return value === null || value === undefined ? '(blank)' : value;
}

/**
 * Builds one row per planned field write, old next to new.
 *
 * @param {{plannedChanges:Array}} result Engine result to render.
 * @returns {Array<object>} Rows keyed for iteration in a template.
 */
export function toPlannedRows(result) {
    const changes = (result && result.plannedChanges) || [];
    return changes.map((change, index) => ({
        key: `${change.recordId}-${change.fieldName}-${index}`,
        field: `${change.objectName}.${change.fieldName}`,
        oldValue: displayValue(change.oldValue),
        newValue: change.newValue,
        grade: change.grade
    }));
}

/**
 * Builds one row per compliance mismatch or near match, stored next to
 * extracted.
 *
 * @param {{findings:Array}} result Engine result to render.
 * @returns {Array<object>} Rows keyed for iteration in a template.
 */
export function toMismatchRows(result) {
    const findings = (result && result.findings) || [];
    return findings
        .filter((finding) => MISMATCH_CODES.includes(finding.code))
        .map((finding, index) => ({
            key: `${finding.recordId}-${finding.fieldName}-${index}`,
            field: `${finding.objectName}.${finding.fieldName}`,
            stored: displayValue(finding.storedValue),
            extracted: finding.extractedValue,
            outcome: finding.compareOutcome,
            jsonPath: finding.jsonPath
        }));
}

/**
 * Selects the findings worth showing a reviewer, as label and css class.
 *
 * Info findings stay out, since an unmatched row is data rather than a
 * problem to act on, and mismatches stay out too when the caller already
 * renders them as rows.
 *
 * @param {{findings:Array}} result Engine result to render.
 * @param {{includeMismatches:boolean}} [options] Whether compared-value
 *        findings stay in the list; true by default.
 * @returns {Array<object>} Items keyed for iteration in a template.
 */
export function toFindingItems(result, { includeMismatches = true } = {}) {
    const findings = (result && result.findings) || [];
    return findings
        .filter(
            (finding) =>
                finding.severity !== 'Info' &&
                (includeMismatches || !MISMATCH_CODES.includes(finding.code))
        )
        .map((finding, index) => ({
            key: `${finding.code}-${index}`,
            label: `${finding.code}: ${finding.message}`,
            cssClass:
                finding.severity === 'Error'
                    ? 'slds-text-color_error'
                    : 'slds-text-color_weak'
        }));
}
