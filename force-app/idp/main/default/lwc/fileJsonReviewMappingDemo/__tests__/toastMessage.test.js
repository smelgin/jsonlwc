import FileJsonReviewMappingDemo from 'c/fileJsonReviewMappingDemo';

jest.mock(
    '@salesforce/apex/IdpMappingController.apply',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/IdpMappingController.preview',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    'c/idpResultFormat',
    () => ({
        toPlannedRows: jest.fn(() => []),
        toMismatchRows: jest.fn(() => []),
        toFindingItems: jest.fn(() => [])
    }),
    { virtual: true }
);

jest.mock(
    'lightning/platformShowToastEvent',
    () => ({ ShowToastEvent: jest.fn() }),
    { virtual: true }
);

/**
 * Bare instance that exposes the component's own methods without
 * going through LWC's element bridge (which hides non-@api members).
 */
const proto = FileJsonReviewMappingDemo.prototype;
const cmp = Object.create(proto);

function buildResult(overrides = {}) {
    return {
        success: true,
        compliant: true,
        fieldsApplied: 0,
        fieldsCompared: 0,
        rowsCreated: 0,
        rowsUpdated: 0,
        updatedRecordIds: [],
        createdRecordIds: [],
        findings: [],
        plannedChanges: [],
        ...overrides
    };
}

describe('toastMessage', () => {
    it('shows fields applied to updated records', () => {
        const result = buildResult({
            fieldsApplied: 5,
            updatedRecordIds: ['001x', '001y']
        });
        expect(cmp.toastMessage(result)).toBe(
            '5 field(s) applied to 2 record(s)'
        );
    });

    it('shows created records when rowsCreated > 0', () => {
        const result = buildResult({
            rowsCreated: 6,
            createdRecordIds: ['a01a', 'a01b', 'a01c', 'a01d', 'a01e', 'a01f']
        });
        expect(cmp.toastMessage(result)).toBe('6 record(s) created');
    });

    it('shows both applied and created together', () => {
        const result = buildResult({
            fieldsApplied: 3,
            updatedRecordIds: ['001x'],
            rowsCreated: 6,
            createdRecordIds: ['a01a', 'a01b', 'a01c', 'a01d', 'a01e', 'a01f']
        });
        expect(cmp.toastMessage(result)).toBe(
            '3 field(s) applied to 1 record(s); 6 record(s) created'
        );
    });

    it('shows applied, created, and compliance together', () => {
        const result = buildResult({
            fieldsApplied: 3,
            updatedRecordIds: ['001x'],
            rowsCreated: 2,
            createdRecordIds: ['a01a', 'a01b'],
            fieldsCompared: 4,
            findings: [{ code: 'VALUE_MISMATCH' }]
        });
        expect(cmp.toastMessage(result)).toBe(
            '3 field(s) applied to 1 record(s); 2 record(s) created; 4 field(s) checked, 1 mismatch(es)'
        );
    });

    it('omits created section when rowsCreated is 0', () => {
        const result = buildResult({
            fieldsApplied: 2,
            updatedRecordIds: ['001x'],
            rowsCreated: 0
        });
        expect(cmp.toastMessage(result)).toBe(
            '2 field(s) applied to 1 record(s)'
        );
    });

    it('returns fallback when nothing happened', () => {
        const result = buildResult();
        expect(cmp.toastMessage(result)).toBe('Nothing to process.');
    });

    it('shows compliance check only', () => {
        const result = buildResult({
            fieldsCompared: 8,
            findings: []
        });
        expect(cmp.toastMessage(result)).toBe(
            '8 field(s) checked, 0 mismatch(es)'
        );
    });

    it('shows only created when no fields applied', () => {
        const result = buildResult({
            fieldsApplied: 0,
            rowsCreated: 3,
            createdRecordIds: ['a01a', 'a01b', 'a01c']
        });
        expect(cmp.toastMessage(result)).toBe('3 record(s) created');
    });
});

describe('toastTitle', () => {
    it('returns error title on failure', () => {
        const result = buildResult({ success: false });
        expect(cmp.toastTitle(result)).toBe('Completed with problems');
    });

    it('returns compliance mismatch title', () => {
        const result = buildResult({ compliant: false });
        expect(cmp.toastTitle(result)).toBe('Compliance mismatches found');
    });

    it('returns compliance passed when fields compared', () => {
        const result = buildResult({ fieldsCompared: 5 });
        expect(cmp.toastTitle(result)).toBe('Compliance check passed');
    });

    it('returns fields mapped when no comparison', () => {
        const result = buildResult();
        expect(cmp.toastTitle(result)).toBe('Fields mapped');
    });
});
