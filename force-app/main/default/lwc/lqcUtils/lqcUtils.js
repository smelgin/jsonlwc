/**
 * Shared helpers for the Liquidity Calculator components.
 */

/**
 * Derives the camelCase row key for a column label, e.g.
 * "Account Number" -> "accountNumber", "Share Name/Holding" -> "shareNameHolding".
 * Must stay in sync with LqcController.fieldKey in Apex.
 */
export function fieldKey(label) {
    if (!label) {
        return '';
    }
    return label
        .split(/[^a-zA-Z0-9]+/)
        .filter(Boolean)
        .map((word, index) => {
            const lower = word.toLowerCase();
            return index === 0 ? lower : lower.charAt(0).toUpperCase() + lower.slice(1);
        })
        .join('');
}

const NUMBER_TYPE_PATTERN = /^number\((\d+),(\d+)\)$/;

/**
 * Parses a configured column type string into its parts.
 * "number(6,2)" -> { base: 'number', intDigits: 6, decimals: 2 }
 * "number"      -> { base: 'number', decimals: 2 }  (v1 default)
 * anything else -> { base: '<type>' } (text, textLink, date, picklist)
 */
export function parseColumnType(type) {
    if (!type) {
        return { base: 'text' };
    }
    const match = NUMBER_TYPE_PATTERN.exec(type);
    if (match) {
        return {
            base: 'number',
            intDigits: parseInt(match[1], 10),
            decimals: parseInt(match[2], 10)
        };
    }
    if (type === 'number') {
        return { base: 'number', decimals: 2 };
    }
    return { base: type };
}

/**
 * Converts a pipe-separated picklist definition ("Open|Closed|Deferred")
 * into lightning-combobox options. Accepts the legacy "value" key too.
 */
export function picklistOptions(column) {
    const raw = column?.values ?? column?.value ?? '';
    return String(raw)
        .split('|')
        .filter(Boolean)
        .map((entry) => ({ label: entry, value: entry }));
}

/**
 * Converts a configured percentage width ("20%") into an initial pixel width
 * for lightning-datatable (which does not accept percentages). 100% ~ 1200px.
 */
export function widthToPixels(width, totalPixels = 1200) {
    const pct = parseFloat(width);
    if (Number.isNaN(pct) || pct <= 0) {
        return undefined;
    }
    return Math.round((pct / 100) * totalPixels);
}

/**
 * Extracts a user-friendly message from an LWC/Apex error.
 */
export function reduceError(error) {
    if (!error) {
        return 'Unknown error';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    if (error.body && typeof error.body.message === 'string') {
        return error.body.message;
    }
    if (typeof error.message === 'string') {
        return error.message;
    }
    return 'Unknown error';
}
