import { createElement } from 'lwc';
import LiquidityCalculator from 'c/liquidityCalculator';
import getConfig from '@salesforce/apex/LqcController.getConfig';
import getSavedResult from '@salesforce/apex/LqcController.getSavedResult';
import saveResult from '@salesforce/apex/LqcController.saveResult';

jest.mock(
    '@salesforce/apex/LqcController.getConfig',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/LqcController.getSavedResult',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/LqcController.saveResult',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const CONFIG = JSON.stringify({
    tabs: [
        {
            name: 'shares',
            title: 'Shares',
            refreshClass: 'lqcShares',
            canAddRows: true,
            columns: [
                { name: 'Share Name/Holding', type: 'textLink', width: '30%' },
                { name: 'Current Value', type: 'number', width: '30%', subtotal: true }
            ]
        },
        { name: 'otherAssets', title: 'Other Assets' },
        { name: 'estimatedEstateValue', title: 'Estimated Estate Value', type: 'report' }
    ]
});

// eslint-disable-next-line @lwc/lwc/no-async-operation
const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

function buildComponent() {
    const element = createElement('c-liquidity-calculator', {
        is: LiquidityCalculator
    });
    element.recordId = '500000000000000AAA';
    document.body.appendChild(element);
    return element;
}

describe('c-liquidity-calculator', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders one tab per configured entry', async () => {
        getConfig.mockResolvedValue(CONFIG);
        getSavedResult.mockResolvedValue(null);

        const element = buildComponent();
        await flushPromises();

        const tabs = element.shadowRoot.querySelectorAll('lightning-tab');
        expect(tabs).toHaveLength(3);
        expect(tabs[0].label).toBe('Shares');
        expect(tabs[1].label).toBe('Other Assets');
        expect(tabs[2].label).toBe('Estimated Estate Value');
    });

    it('renders the report tab as c-lqc-report and feeds it live rows', async () => {
        getConfig.mockResolvedValue(CONFIG);
        getSavedResult.mockResolvedValue(null);

        const element = buildComponent();
        await flushPromises();

        const report = element.shadowRoot.querySelector('c-lqc-report');
        expect(report).not.toBeNull();
        expect(report.title).toBe('Estimated Estate Value');
        expect(report.tabs).toHaveLength(3);
        // Report tabs never render a grid: one grid per data tab only.
        expect(element.shadowRoot.querySelectorAll('c-lqc-grid')).toHaveLength(2);

        const grid = element.shadowRoot.querySelector('c-lqc-grid');
        grid.dispatchEvent(
            new CustomEvent('rowschange', {
                detail: { name: 'shares', rows: [{ id: 'm1', currentValue: 7 }] }
            })
        );
        await flushPromises();
        expect(report.rowsMap.shares).toHaveLength(1);
    });

    it('shows an error banner when config loading fails', async () => {
        getConfig.mockRejectedValue({ body: { message: 'no config' } });
        getSavedResult.mockResolvedValue(null);

        const element = buildComponent();
        await flushPromises();

        const banner = element.shadowRoot.querySelector('c-lqc-banner');
        expect(banner).not.toBeNull();
        expect(banner.variant).toBe('error');
        expect(banner.message).toContain('no config');
    });

    it('saves the payload with the published flag on Publish', async () => {
        getConfig.mockResolvedValue(CONFIG);
        getSavedResult.mockResolvedValue(null);
        saveResult.mockResolvedValue();

        const element = buildComponent();
        await flushPromises();

        const buttons = [...element.shadowRoot.querySelectorAll('lightning-button')];
        const publishButton = buttons.find((b) => b.label === 'Publish');
        publishButton.click();
        await flushPromises();

        expect(saveResult).toHaveBeenCalledTimes(1);
        const payload = JSON.parse(saveResult.mock.calls[0][0].payload);
        expect(payload.published).toBe(true);
        // Apex resolves the storage target from this config record, server-side.
        expect(saveResult.mock.calls[0][0]).toHaveProperty('configName');

        // After publishing, grids become read-only and actions disabled.
        const grid = element.shadowRoot.querySelector('c-lqc-grid');
        expect(grid.readOnly).toBe(true);
        expect(publishButton.disabled).toBe(true);
    });

    it('restores saved rows into the matching tab', async () => {
        getConfig.mockResolvedValue(CONFIG);
        getSavedResult.mockResolvedValue(
            JSON.stringify({
                version: 1,
                published: false,
                tabs: {
                    shares: [
                        {
                            id: 'shares-manual-1',
                            isManual: true,
                            editable: true,
                            currentValue: 42
                        }
                    ]
                }
            })
        );

        const element = buildComponent();
        await flushPromises();

        const grid = element.shadowRoot.querySelector('c-lqc-grid');
        expect(grid.initialRows).toHaveLength(1);
        expect(grid.initialRows[0].currentValue).toBe(42);
    });
});
