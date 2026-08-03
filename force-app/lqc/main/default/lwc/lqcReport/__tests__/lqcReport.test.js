import { createElement } from 'lwc';
import LqcReport from 'c/lqcReport';

const TABS = [
    {
        name: 'insurancePolicies',
        title: 'Insurance Policies',
        columns: [
            { name: 'Policy Number', type: 'textLink', width: '20%' },
            {
                name: 'Policy Type',
                type: 'picklist',
                values: 'Vehicle|Home|Life',
                groupBy: true,
                width: '10%'
            },
            { name: 'Cover Amount', type: 'number(6,2)', width: '20%', subtotal: true }
        ]
    },
    {
        name: 'shares',
        title: 'Shares',
        columns: [
            { name: 'Share Name/Holding', type: 'text', width: '30%' },
            { name: 'Current Value', type: 'number(6,2)', width: '30%', subtotal: true }
        ]
    },
    // No subtotal column -> excluded from the report.
    { name: 'estimatedEstateValue', title: 'Estimated Estate Value', type: 'report' }
];

const ROWS_MAP = {
    insurancePolicies: [
        { id: 'i1', policyType: 'Life', coverAmount: 100 },
        { id: 'i2', policyType: 'Life', coverAmount: 50 },
        { id: 'i3', policyType: 'Home', coverAmount: 200 }
    ],
    shares: [
        { id: 's1', currentValue: 1000 },
        { id: 's2', currentValue: 500 }
    ]
};

function buildComponent(rowsMap = ROWS_MAP) {
    const element = createElement('c-lqc-report', { is: LqcReport });
    element.title = 'Estimated Estate Value';
    element.tabs = TABS;
    element.rowsMap = rowsMap;
    document.body.appendChild(element);
    return element;
}

function rowTexts(element, selector) {
    return [...element.shadowRoot.querySelectorAll(selector)].map((row) =>
        [...row.children].map((cell) => cell.textContent.trim()).join(' | ')
    );
}

describe('c-lqc-report', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders a grey section row per subtotal tab with the Value label', () => {
        const element = buildComponent();

        const sections = rowTexts(element, '.lqc-report__section-row');
        expect(sections).toEqual(['Insurance Policies | Value', 'Shares | Value']);
    });

    it('groups by the groupBy column, or shows a single Total line', () => {
        const element = buildComponent();

        const lines = rowTexts(element, '.lqc-report__line-row');
        expect(lines).toEqual(['Life | 150', 'Home | 200', 'Total | 1,500']);
    });

    it('shows the grand total as a simple sum of all tab subtotals', () => {
        const element = buildComponent();

        const grand = element.shadowRoot.querySelector('.lqc-report__grand-total-row');
        expect(grand.textContent).toContain('Estimated Net Estate Value');
        expect(grand.textContent).toContain('1,850');
    });

    it('formats amounts as currency when currencyCode is set', () => {
        const element = createElement('c-lqc-report', { is: LqcReport });
        element.title = 'Estimated Net Estate Value';
        element.tabs = TABS;
        element.rowsMap = ROWS_MAP;
        element.currencyCode = 'ZAR';
        document.body.appendChild(element);

        const grand = element.shadowRoot.querySelector(
            '.lqc-report__grand-total-amount'
        );
        // en-US test locale renders ZAR as "ZAR 1,850"; en-ZA orgs show "R1 850".
        expect(grand.textContent).toMatch(/ZAR|R/);
        expect(grand.textContent).toContain('1,850');
    });

    it('recomputes when rowsMap is replaced (live updates from other tabs)', async () => {
        const element = buildComponent();

        element.rowsMap = {
            ...ROWS_MAP,
            shares: [...ROWS_MAP.shares, { id: 's3', currentValue: 150 }]
        };
        await Promise.resolve();

        const grand = element.shadowRoot.querySelector('.lqc-report__grand-total-row');
        expect(grand.textContent).toContain('2,000');
    });

    it('shows zero-amount Total lines when a tab has no rows yet', () => {
        const element = buildComponent({});

        const lines = rowTexts(element, '.lqc-report__line-row');
        expect(lines).toEqual(['Total | 0', 'Total | 0']);
        const grand = element.shadowRoot.querySelector('.lqc-report__grand-total-row');
        expect(grand.textContent).toContain('0');
    });

    it('exposes a refresh icon that emits a refresh event', () => {
        const element = buildComponent();
        const refreshHandler = jest.fn();
        element.addEventListener('refresh', refreshHandler);

        element.shadowRoot.querySelector('lightning-button-icon').click();

        expect(refreshHandler).toHaveBeenCalledTimes(1);
    });
});
