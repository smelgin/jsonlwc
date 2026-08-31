/**
 * Turns an IdpResult.Result into rows a template can iterate — shared by
 * every component that renders an engine result (c-file-json-review's
 * preview panel, c-file-json-review-mapping-demo's result card), so the
 * presentation of a result lives in exactly one place and cannot drift.
 *
 * Pure functions over plain data: no Apex, no DOM, no component state.
 */

const MISMATCH_CODES = ['VALUE_MISMATCH', 'VALUE_NEAR'];

/** A null/undefined stored value reads as blank, not as the word "null". */
function displayValue(value) {
    return value === null || value === undefined ? '(blank)' : value;
}

/** One row per planned field write, old → new, keyed for for:each. */
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

/** One row per compliance mismatch or near match, stored vs extracted. */
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
 * The findings worth showing a reviewer, as label + css class. Info stays
 * out (an unmatched row is data, not a problem to act on), and mismatches
 * stay out too when the caller renders them as rows via toMismatchRows —
 * pass includeMismatches: true to keep them in the list instead.
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
