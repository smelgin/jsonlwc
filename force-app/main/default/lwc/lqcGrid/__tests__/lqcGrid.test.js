import { createElement } from 'lwc';
import LqcGrid from 'c/lqcGrid';
import refreshRows from '@salesforce/apex/LqcController.refreshRows';

jest.mock(
    '@salesforce/apex/LqcController.refreshRows',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const TAB_CONFIG = {
    name: 'shares',
    title: 'Shares',
    refreshClass: 'lqcShares',
    canAddRows: true,
    columns: [
        { name: 'Share Name/Holding', type: 'textLink', width: '30%' },
        { name: 'Number of Shares', type: 'number', width: '20%' },
        { name: 'Current Value', type: 'number(6,2)', width: '30%', subtotal: true },
        { name: 'Status', type: 'picklist', values: 'Active|Sold', width: '20%' }
    ]
};

// eslint-disable-next-line @lwc/lwc/no-async-operation
const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

function buildComponent(overrides = {}) {
    const element = createElement('c-lqc-grid', { is: LqcGrid });
    Object.assign(element, {
        recordId: '500000000000000AAA',
        config: TAB_CONFIG,
        initialRows: [],
        ...overrides
    });
    document.body.appendChild(element);
    return element;
}

describe('c-lqc-grid', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders the configured title and only the Add button', () => {
        const element = buildComponent();

        const title = element.shadowRoot.querySelector('.lqc-grid__title');
        expect(title.textContent).toBe('Shares');

        const buttons = [...element.shadowRoot.querySelectorAll('lightning-button')];
        expect(buttons.map((b) => b.label)).toEqual(['+ Add']);
        expect(buttons[0].disabled).toBeFalsy();
    });

    it('replaces prefilled rows on refresh, keeps manual ones, shows success banner', async () => {
        refreshRows.mockResolvedValue(
            JSON.stringify([
                {
                    shareNameHolding: '0000006453',
                    shareNameHoldingRecordId: '500000000000000AAA',
                    numberOfShares: 100,
                    currentValue: 1500000,
                    status: 'Active'
                }
            ])
        );
        const element = buildComponent({
            initialRows: [
                { id: 'shares-manual-1', isManual: true, editable: true, status: 'Manual' },
                { id: 'shares-prefill-old', isManual: false, editable: false, status: 'Old' }
            ]
        });
        const rowsChange = jest.fn();
        element.addEventListener('rowschange', rowsChange);

        element.shadowRoot
            .querySelector('lightning-button-icon')
            .click();
        await flushPromises();

        expect(refreshRows).toHaveBeenCalledWith({
            className: 'lqcShares',
            recordId: '500000000000000AAA'
        });
        const { rows } = rowsChange.mock.calls[0][0].detail;
        expect(rows).toHaveLength(2); // 1 new prefill + 1 manual kept
        const prefill = rows.find((r) => !r.isManual);
        expect(prefill.shareNameHoldingUrl).toBe(
            '/lightning/r/500000000000000AAA/view'
        );
        expect(rows.some((r) => r.status === 'Old')).toBe(false);

        const banner = element.shadowRoot.querySelector('c-lqc-banner');
        expect(banner.variant).toBe('success');
        expect(banner.message).toBe('Shares Extract - Success');
    });

    it('shows an error banner when refresh fails', async () => {
        refreshRows.mockRejectedValue({ body: { message: 'kaboom' } });
        const element = buildComponent();

        element.shadowRoot
            .querySelector('lightning-button-icon')
            .click();
        await flushPromises();

        const banner = element.shadowRoot.querySelector('c-lqc-banner');
        expect(banner.variant).toBe('error');
        expect(banner.message).toContain('kaboom');
    });

    it('adds a manual row through the modal', async () => {
        const element = buildComponent();
        const rowsChange = jest.fn();
        element.addEventListener('rowschange', rowsChange);

        const buttons = [...element.shadowRoot.querySelectorAll('lightning-button')];
        buttons.find((b) => b.label === '+ Add').click();
        await flushPromises();

        // textLink column is excluded; picklist renders as a combobox.
        const inputs = [
            ...element.shadowRoot.querySelectorAll('lightning-input[data-key]')
        ];
        expect(inputs).toHaveLength(2);
        const combobox = element.shadowRoot.querySelector(
            'lightning-combobox[data-key]'
        );
        expect(combobox).not.toBeNull();
        expect(combobox.options).toEqual([
            { label: 'Active', value: 'Active' },
            { label: 'Sold', value: 'Sold' }
        ]);

        inputs.forEach((input) => {
            input.reportValidity = jest.fn(() => true);
            input.value = '250';
            input.dispatchEvent(new CustomEvent('change'));
        });
        combobox.reportValidity = jest.fn(() => true);
        combobox.value = 'Sold';
        combobox.dispatchEvent(new CustomEvent('change'));

        const modalButtons = [
            ...element.shadowRoot.querySelectorAll('lightning-button')
        ];
        modalButtons.find((b) => b.label === 'Add').click();
        await flushPromises();

        const { rows } = rowsChange.mock.calls[0][0].detail;
        expect(rows).toHaveLength(1);
        expect(rows[0].isManual).toBe(true);
        expect(rows[0].editable).toBe(true);
        expect(rows[0].numberOfShares).toBe(250);
        expect(rows[0].currentValue).toBe(250);
        expect(rows[0].status).toBe('Sold');
    });

    it('renders a blank body for tabs without columns', () => {
        const element = buildComponent({
            config: { name: 'otherAssets', title: 'Other Assets' }
        });
        expect(element.shadowRoot.querySelector('c-lqc-datatable')).toBeNull();
        expect(element.shadowRoot.textContent).toContain('Available in a future version.');
    });
});
