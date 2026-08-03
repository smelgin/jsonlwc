import {
    fieldKey,
    widthToPixels,
    reduceError,
    parseColumnType,
    picklistOptions
} from 'c/lqcUtils';

describe('c-lqc-utils', () => {
    describe('fieldKey', () => {
        it('derives camelCase keys from column labels', () => {
            expect(fieldKey('Account Number')).toBe('accountNumber');
            expect(fieldKey('Balance at DoD')).toBe('balanceAtDod');
            expect(fieldKey('Share Name/Holding')).toBe('shareNameHolding');
            expect(fieldKey('Interest on Acct')).toBe('interestOnAcct');
        });

        it('handles blank input', () => {
            expect(fieldKey('')).toBe('');
            expect(fieldKey(undefined)).toBe('');
        });
    });

    describe('widthToPixels', () => {
        it('converts percentages against a 1200px baseline', () => {
            expect(widthToPixels('20%')).toBe(240);
            expect(widthToPixels('10%')).toBe(120);
        });

        it('returns undefined for invalid widths', () => {
            expect(widthToPixels('abc')).toBeUndefined();
            expect(widthToPixels(undefined)).toBeUndefined();
        });
    });

    describe('parseColumnType', () => {
        it('parses number(precision,scale)', () => {
            expect(parseColumnType('number(6,2)')).toEqual({
                base: 'number',
                intDigits: 6,
                decimals: 2
            });
        });

        it('defaults plain number to 2 decimals', () => {
            expect(parseColumnType('number')).toEqual({ base: 'number', decimals: 2 });
        });

        it('passes other types through and defaults blank to text', () => {
            expect(parseColumnType('picklist')).toEqual({ base: 'picklist' });
            expect(parseColumnType('textLink')).toEqual({ base: 'textLink' });
            expect(parseColumnType(undefined)).toEqual({ base: 'text' });
        });
    });

    describe('picklistOptions', () => {
        it('builds combobox options from the pipe-separated values key', () => {
            expect(picklistOptions({ values: 'Open|Closed|Deferred' })).toEqual([
                { label: 'Open', value: 'Open' },
                { label: 'Closed', value: 'Closed' },
                { label: 'Deferred', value: 'Deferred' }
            ]);
        });

        it('accepts the legacy singular "value" key and empty input', () => {
            expect(picklistOptions({ value: 'Credit' })).toEqual([
                { label: 'Credit', value: 'Credit' }
            ]);
            expect(picklistOptions({})).toEqual([]);
            expect(picklistOptions(undefined)).toEqual([]);
        });
    });

    describe('reduceError', () => {
        it('reads Apex AuraHandledException bodies', () => {
            expect(reduceError({ body: { message: 'boom' } })).toBe('boom');
        });

        it('joins array bodies', () => {
            expect(
                reduceError({ body: [{ message: 'one' }, { message: 'two' }] })
            ).toBe('one, two');
        });

        it('falls back to error.message and a default', () => {
            expect(reduceError(new Error('plain'))).toBe('plain');
            expect(reduceError(undefined)).toBe('Unknown error');
        });
    });
});
