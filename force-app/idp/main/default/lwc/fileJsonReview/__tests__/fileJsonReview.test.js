import { createElement } from 'lwc';
import FileJsonReview from 'c/fileJsonReview';
import getFileInfo from '@salesforce/apex/FilePreviewController.getFileInfo';
import getFileBase64 from '@salesforce/apex/FilePreviewController.getFileBase64';

jest.mock(
    '@salesforce/apex/FilePreviewController.getFileInfo',
    () => {
        const {
            createApexTestWireAdapter
        } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/FilePreviewController.getFileBase64',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const SAMPLE_JSON = JSON.stringify({
    'First Name': 'Carlos',
    Age: 45
});

const PDF_FILE = {
    title: 'Contract',
    fileExtension: 'pdf',
    contentSize: 50000,
    contentVersionId: '068000000000001AAA'
};

const IMAGE_FILE = {
    title: 'Photo',
    fileExtension: 'png',
    contentSize: 50000,
    contentVersionId: '068000000000002AAA'
};

function buildComponent(props = {}) {
    const element = createElement('c-file-json-review', {
        is: FileJsonReview
    });
    Object.assign(element, props);
    document.body.appendChild(element);
    return element;
}

async function flushPromises() {
    // Drain a few microtask turns so imperative-Apex promise chains and the
    // reactive re-render they trigger both settle.
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
}

describe('c-file-json-review', () => {
    beforeEach(() => {
        getFileBase64.mockResolvedValue('QkFTRTY0');
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('prompts for a document id when none is set', () => {
        const element = buildComponent({ jsonInput: SAMPLE_JSON });
        const message = element.shadowRoot.querySelector('.pane-message');
        expect(message.textContent).toContain('Set a Content Document Id');
    });

    it('renders a PDF through the bundled PDF.js viewer', async () => {
        const element = buildComponent({
            contentDocumentId: '069000000000001AAA',
            jsonInput: SAMPLE_JSON
        });
        getFileInfo.emit(PDF_FILE);
        await flushPromises();

        expect(getFileBase64).toHaveBeenCalledWith({
            contentVersionId: '068000000000001AAA'
        });
        const frame = element.shadowRoot.querySelector('.preview-frame');
        expect(frame).not.toBeNull();
        expect(frame.src).toContain('viewer.html');
        expect(frame.src).toContain('v=068000000000001AAA');
    });

    it('falls back to the native preview when the PDF is too large', async () => {
        const element = buildComponent({
            contentDocumentId: '069000000000001AAA',
            jsonInput: SAMPLE_JSON
        });
        getFileInfo.emit({ ...PDF_FILE, contentSize: 20 * 1024 * 1024 });
        await flushPromises();

        expect(getFileBase64).not.toHaveBeenCalled();
        const frame = element.shadowRoot.querySelector('.preview-frame');
        expect(frame.src).toContain(
            '/sfc/servlet.shepherd/version/download/068000000000001AAA'
        );
    });

    it('falls back to the native preview when the viewer never loads', async () => {
        jest.useFakeTimers();
        try {
            const element = buildComponent({
                contentDocumentId: '069000000000001AAA',
                jsonInput: SAMPLE_JSON
            });
            getFileInfo.emit(PDF_FILE);
            await flushPromises();

            // Viewer iframe present but never posts "ready".
            expect(
                element.shadowRoot.querySelector('.preview-frame').src
            ).toContain('viewer.html');

            jest.runOnlyPendingTimers();
            await flushPromises();

            const frame = element.shadowRoot.querySelector('.preview-frame');
            expect(frame.src).toContain(
                '/sfc/servlet.shepherd/version/download/068000000000001AAA'
            );
        } finally {
            jest.useRealTimers();
        }
    });

    it('falls back to the native preview when the byte fetch fails', async () => {
        getFileBase64.mockRejectedValueOnce(new Error('nope'));
        const element = buildComponent({
            contentDocumentId: '069000000000001AAA',
            jsonInput: SAMPLE_JSON
        });
        getFileInfo.emit(PDF_FILE);
        await flushPromises();

        const frame = element.shadowRoot.querySelector('.preview-frame');
        expect(frame.src).toContain(
            '/sfc/servlet.shepherd/version/download/068000000000001AAA'
        );
    });

    it('renders an image in an img tag', async () => {
        const element = buildComponent({
            contentDocumentId: '069000000000002AAA',
            jsonInput: SAMPLE_JSON
        });
        getFileInfo.emit(IMAGE_FILE);
        await flushPromises();

        const img = element.shadowRoot.querySelector('.preview-image');
        expect(img).not.toBeNull();
        expect(img.src).toContain(
            '/sfc/servlet.shepherd/version/download/068000000000002AAA'
        );
        expect(element.shadowRoot.querySelector('.preview-frame')).toBeNull();
    });

    it('shows a message for unsupported file types', async () => {
        const element = buildComponent({
            contentDocumentId: '069000000000003AAA',
            jsonInput: SAMPLE_JSON
        });
        getFileInfo.emit({
            title: 'Data',
            fileExtension: 'xlsx',
            contentVersionId: '068000000000003AAA'
        });
        await flushPromises();

        const message = element.shadowRoot.querySelector('.pane-message');
        expect(message.textContent).toContain('Preview not available');
    });

    it('shows the Apex error message when the file cannot be loaded', async () => {
        const element = buildComponent({
            contentDocumentId: '069000000000004AAA',
            jsonInput: SAMPLE_JSON
        });
        getFileInfo.error({ message: 'File not found' });
        await flushPromises();

        const message = element.shadowRoot.querySelector(
            '.slds-text-color_error'
        );
        expect(message.textContent).toBe('File not found');
    });

    it('passes jsonInput to the child form and exposes edits via jsonOutput', async () => {
        const element = buildComponent({ jsonInput: SAMPLE_JSON });
        const handler = jest.fn();
        const flowHandler = jest.fn();
        element.addEventListener('jsonchange', handler);
        element.addEventListener('lightning__flowattributechange', flowHandler);

        const form = element.shadowRoot.querySelector('c-json-form');
        expect(form.jsonData).toEqual(JSON.parse(SAMPLE_JSON));
        expect(element.jsonOutput).toBe(SAMPLE_JSON);

        const ageInput = [
            ...form.shadowRoot.querySelectorAll('.value-input')
        ][1];
        ageInput.value = '46';
        ageInput.dispatchEvent(new CustomEvent('change'));

        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.value.Age).toBe(46);
        expect(JSON.parse(element.jsonOutput).Age).toBe(46);
        expect(flowHandler).toHaveBeenCalled();
    });

    it('leaves the JSON field names read-only unless editLabels is set', () => {
        const element = buildComponent({ jsonInput: SAMPLE_JSON });
        const form = element.shadowRoot.querySelector('c-json-form');
        expect(form.editLabels).toBe(false);
        expect(form.shadowRoot.querySelectorAll('.label-input')).toHaveLength(
            0
        );
    });

    it('passes editLabels through to the child form', () => {
        const element = buildComponent({
            jsonInput: SAMPLE_JSON,
            editLabels: true
        });
        const form = element.shadowRoot.querySelector('c-json-form');
        expect(form.editLabels).toBe(true);
        // 2 object keys, both renameable
        expect(form.shadowRoot.querySelectorAll('.label-input')).toHaveLength(
            2
        );
    });

    it('returns the current JSON via jsonsubmit when the button is clicked', async () => {
        const element = buildComponent({ jsonInput: SAMPLE_JSON });
        const submitHandler = jest.fn();
        element.addEventListener('jsonsubmit', submitHandler);

        // Edit a value first.
        const form = element.shadowRoot.querySelector('c-json-form');
        const ageInput = [
            ...form.shadowRoot.querySelectorAll('.value-input')
        ][1];
        ageInput.value = '46';
        ageInput.dispatchEvent(new CustomEvent('change'));

        const button = element.shadowRoot.querySelector('lightning-button');
        button.click();
        await flushPromises();

        expect(submitHandler).toHaveBeenCalledTimes(1);
        const detail = submitHandler.mock.calls[0][0].detail;
        expect(detail.value.Age).toBe(46);
        expect(detail.value['First Name']).toBe('Carlos');
        expect(JSON.parse(detail.jsonString).Age).toBe(46);
    });

    it('disables the save button when there is no JSON to return', () => {
        const element = buildComponent({});
        const button = element.shadowRoot.querySelector('lightning-button');
        expect(button.disabled).toBe(true);
    });

    it('uses a configurable save button label', () => {
        const element = buildComponent({
            jsonInput: SAMPLE_JSON,
            submitLabel: 'Store JSON'
        });
        const button = element.shadowRoot.querySelector('lightning-button');
        expect(button.label).toBe('Store JSON');
        expect(button.disabled).toBe(false);
    });

    it('resizes the panes when the divider is dragged', async () => {
        const element = buildComponent({ jsonInput: SAMPLE_JSON });
        const container = element.shadowRoot.querySelector('.split-container');
        container.getBoundingClientRect = jest.fn(() => ({
            left: 0,
            width: 1000
        }));

        const divider = element.shadowRoot.querySelector('.divider');
        divider.dispatchEvent(
            new MouseEvent('pointerdown', { clientX: 500, bubbles: true })
        );
        window.dispatchEvent(
            new MouseEvent('pointermove', { clientX: 300, bubbles: true })
        );
        window.dispatchEvent(new MouseEvent('pointerup', { bubbles: true }));
        await flushPromises();

        const leftPane = element.shadowRoot.querySelector('.left-pane');
        expect(leftPane.style.width).toBe('30%');
    });

    it('clamps the divider position and supports the keyboard', async () => {
        const element = buildComponent({ jsonInput: SAMPLE_JSON });
        const container = element.shadowRoot.querySelector('.split-container');
        container.getBoundingClientRect = jest.fn(() => ({
            left: 0,
            width: 1000
        }));

        const divider = element.shadowRoot.querySelector('.divider');
        divider.dispatchEvent(
            new MouseEvent('pointerdown', { clientX: 500, bubbles: true })
        );
        window.dispatchEvent(
            new MouseEvent('pointermove', { clientX: 50, bubbles: true })
        );
        window.dispatchEvent(new MouseEvent('pointerup', { bubbles: true }));
        await flushPromises();

        const leftPane = element.shadowRoot.querySelector('.left-pane');
        expect(leftPane.style.width).toBe('20%');

        divider.dispatchEvent(
            new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true })
        );
        await flushPromises();
        expect(leftPane.style.width).toBe('22%');
    });
});
