import { createElement } from 'lwc';
import FileJsonReview from 'c/fileJsonReview';
import getFileInfo from '@salesforce/apex/FilePreviewController.getFileInfo';
import getFileBase64 from '@salesforce/apex/FilePreviewController.getFileBase64';
import previewMapping from '@salesforce/apex/IdpMappingController.preview';

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

jest.mock(
    '@salesforce/apex/IdpMappingController.preview',
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

/** The Save button is always the last one in the footer. */
function saveButton(element) {
    const buttons = [
        ...element.shadowRoot.querySelectorAll('.right-footer lightning-button')
    ];
    return buttons[buttons.length - 1];
}

/** Stands in for c-json-form telling the host about an edit. */
function fireJsonChange(element, value, valid) {
    element.shadowRoot.querySelector('c-json-form').dispatchEvent(
        new CustomEvent('jsonchange', {
            detail: { value, jsonString: JSON.stringify(value), valid }
        })
    );
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

    // -----------------------------------------------------------------
    // FJR-1 - forwarding the form's capabilities
    // -----------------------------------------------------------------

    describe('forwarding the jsonForm flags', () => {
        it('leaves every capability off when the host sets none', () => {
            const element = buildComponent({ jsonInput: SAMPLE_JSON });
            const form = element.shadowRoot.querySelector('c-json-form');

            expect(form.editStructure).toBe(false);
            expect(form.collapsible).toBe(false);
            expect(form.searchable).toBe(false);
            expect(form.showConfidence).toBe(false);
            expect(form.validateTypes).toBe(false);
            // No toolbar and no add controls: the plain value-editing form
            expect(
                form.shadowRoot.querySelector('.json-form-toolbar')
            ).toBeNull();
            expect(
                form.shadowRoot.querySelectorAll('.add-button')
            ).toHaveLength(0);
        });

        it('forwards each flag to the child form', () => {
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                editStructure: true,
                collapsible: true,
                searchable: true,
                showConfidence: true,
                validateTypes: true
            });
            const form = element.shadowRoot.querySelector('c-json-form');

            expect(form.editStructure).toBe(true);
            expect(form.collapsible).toBe(true);
            expect(form.searchable).toBe(true);
            expect(form.showConfidence).toBe(true);
            expect(form.validateTypes).toBe(true);
            // And they reached the rendering, not just the property
            expect(
                form.shadowRoot.querySelector('.json-form-toolbar')
            ).not.toBeNull();
            expect(
                form.shadowRoot.querySelector('.search-input')
            ).not.toBeNull();
        });

        it('forwards the confidence threshold', () => {
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                showConfidence: true,
                confidenceThreshold: 0.5
            });
            const form = element.shadowRoot.querySelector('c-json-form');
            expect(form.confidenceThreshold).toBe(0.5);
        });

        it('accepts the strings Flow and App Builder pass', () => {
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                editStructure: 'true',
                searchable: 'true'
            });
            const form = element.shadowRoot.querySelector('c-json-form');
            // The child owns the coercion, so they arrive resolved
            expect(form.editStructure).toBe(true);
            expect(form.searchable).toBe(true);
        });
    });

    // -----------------------------------------------------------------
    // FJR-6 - blocking Save on invalid fields
    // -----------------------------------------------------------------

    describe('blocking save on invalid fields', () => {
        it('blocks Save while a field is the wrong type', async () => {
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                validateTypes: true
            });
            expect(saveButton(element).disabled).toBe(false);

            fireJsonChange(
                element,
                { 'First Name': 'Carlos', Age: 'forty' },
                false
            );
            await flushPromises();

            expect(saveButton(element).disabled).toBe(true);
            expect(
                element.shadowRoot.querySelector('.blocked-message').textContent
            ).toContain('Fix the highlighted fields');
        });

        it('releases Save once the value is corrected', async () => {
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                validateTypes: true
            });
            fireJsonChange(
                element,
                { 'First Name': 'Carlos', Age: 'forty' },
                false
            );
            await flushPromises();
            expect(saveButton(element).disabled).toBe(true);

            fireJsonChange(element, { 'First Name': 'Carlos', Age: 46 }, true);
            await flushPromises();
            expect(saveButton(element).disabled).toBe(false);
            expect(
                element.shadowRoot.querySelector('.blocked-message')
            ).toBeNull();
        });

        it('does not block Save when the form is not validating types', async () => {
            const element = buildComponent({ jsonInput: SAMPLE_JSON });
            // A form with validation off always reports itself valid
            fireJsonChange(
                element,
                { 'First Name': 'Carlos', Age: 'forty' },
                true
            );
            await flushPromises();
            expect(saveButton(element).disabled).toBe(false);
        });

        it('clears a blocked state when fresh JSON is loaded', async () => {
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                validateTypes: true
            });
            fireJsonChange(element, { Age: 'forty' }, false);
            await flushPromises();
            expect(saveButton(element).disabled).toBe(true);

            element.jsonInput = SAMPLE_JSON;
            await flushPromises();
            expect(saveButton(element).disabled).toBe(false);
        });
    });

    // -----------------------------------------------------------------
    // FJR-2 - previewing the planned changes
    // -----------------------------------------------------------------

    describe('previewing the planned changes', () => {
        function clickPreview(element) {
            element.shadowRoot
                .querySelector('.preview-button')
                .dispatchEvent(new CustomEvent('click'));
        }

        it('offers no Preview button without a mapping set', () => {
            const element = buildComponent({ jsonInput: SAMPLE_JSON });
            expect(
                element.shadowRoot.querySelector('.preview-button')
            ).toBeNull();
            expect(previewMapping).not.toHaveBeenCalled();
        });

        it('asks the engine what a save would change and lists it', async () => {
            previewMapping.mockResolvedValue({
                success: true,
                plannedChanges: [
                    {
                        objectName: 'Account',
                        fieldName: 'Name',
                        recordId: '001',
                        oldValue: 'Old Co',
                        newValue: 'Blue Harbour',
                        grade: 'Exact'
                    },
                    {
                        objectName: 'Account',
                        fieldName: 'Phone',
                        recordId: '001',
                        oldValue: null,
                        newValue: '+27115550100',
                        grade: 'Inferred'
                    }
                ],
                findings: []
            });
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                contentDocumentId: '069000000000001AAA',
                mappingSetName: 'Estate_Intake'
            });

            clickPreview(element);
            await flushPromises();

            expect(previewMapping).toHaveBeenCalledWith({
                contentDocumentId: '069000000000001AAA',
                jsonString: SAMPLE_JSON,
                mappingSetName: 'Estate_Intake'
            });

            const rows = [
                ...element.shadowRoot.querySelectorAll(
                    '.preview-table tbody tr'
                )
            ];
            expect(rows).toHaveLength(2);
            expect(rows[0].textContent).toContain('Account.Name');
            expect(rows[0].textContent).toContain('Old Co');
            expect(rows[0].textContent).toContain('Blue Harbour');
            // A null old value reads as blank, not as the word "null"
            expect(rows[1].textContent).toContain('(blank)');
            expect(
                element.shadowRoot.querySelector('.preview-message').textContent
            ).toContain('2 fields would change');
        });

        it('says so when nothing would change', async () => {
            previewMapping.mockResolvedValue({
                success: true,
                plannedChanges: [],
                findings: []
            });
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                mappingSetName: 'Estate_Intake'
            });

            clickPreview(element);
            await flushPromises();

            expect(
                element.shadowRoot.querySelector('.preview-message').textContent
            ).toContain('would change nothing');
            expect(
                element.shadowRoot.querySelector('.preview-table')
            ).toBeNull();
        });

        it('lists findings worth acting on and leaves Info out', async () => {
            previewMapping.mockResolvedValue({
                success: false,
                plannedChanges: [],
                findings: [
                    {
                        code: 'PARSE_FAILED',
                        severity: 'Error',
                        message: 'Could not read the date.'
                    },
                    {
                        code: 'ROW_UNMATCHED',
                        severity: 'Info',
                        message: 'No record matches that key.'
                    }
                ]
            });
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                mappingSetName: 'Estate_Intake'
            });

            clickPreview(element);
            await flushPromises();

            const findings = [
                ...element.shadowRoot.querySelectorAll('.preview-findings li')
            ];
            expect(findings).toHaveLength(1);
            expect(findings[0].textContent).toContain('PARSE_FAILED');
        });

        it('reports an Apex failure instead of a diff', async () => {
            previewMapping.mockRejectedValue({
                body: { message: 'No mapping set named Nope was found.' }
            });
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                mappingSetName: 'Nope'
            });

            clickPreview(element);
            await flushPromises();

            expect(
                element.shadowRoot.querySelector('.preview-panel').textContent
            ).toContain('No mapping set named');
        });

        it('writes nothing on its own, so Save still emits jsonsubmit', async () => {
            previewMapping.mockResolvedValue({
                success: true,
                plannedChanges: [],
                findings: []
            });
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                mappingSetName: 'Estate_Intake'
            });
            const submitted = jest.fn();
            element.addEventListener('jsonsubmit', submitted);

            clickPreview(element);
            await flushPromises();
            expect(submitted).not.toHaveBeenCalled();

            saveButton(element).dispatchEvent(new CustomEvent('click'));
            expect(submitted).toHaveBeenCalledTimes(1);
        });

        it('dismisses the panel on request', async () => {
            previewMapping.mockResolvedValue({
                success: true,
                plannedChanges: [],
                findings: []
            });
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                mappingSetName: 'Estate_Intake'
            });
            clickPreview(element);
            await flushPromises();
            expect(
                element.shadowRoot.querySelector('.preview-panel')
            ).not.toBeNull();

            element.shadowRoot
                .querySelector('.preview-dismiss')
                .dispatchEvent(new CustomEvent('click'));
            await flushPromises();
            expect(
                element.shadowRoot.querySelector('.preview-panel')
            ).toBeNull();
        });

        it('drops a preview the next edit has made stale', async () => {
            previewMapping.mockResolvedValue({
                success: true,
                plannedChanges: [
                    {
                        objectName: 'Account',
                        fieldName: 'Name',
                        recordId: '001',
                        oldValue: 'Old Co',
                        newValue: 'Blue Harbour',
                        grade: 'Exact'
                    }
                ],
                findings: []
            });
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                mappingSetName: 'Estate_Intake'
            });
            clickPreview(element);
            await flushPromises();
            expect(
                element.shadowRoot.querySelector('.preview-panel')
            ).not.toBeNull();

            fireJsonChange(element, { 'First Name': 'Carla', Age: 45 }, true);
            await flushPromises();
            expect(
                element.shadowRoot.querySelector('.preview-panel')
            ).toBeNull();
        });

        it('shows what it is doing while the engine is thinking', async () => {
            let release;
            previewMapping.mockReturnValue(
                new Promise((resolve) => {
                    release = resolve;
                })
            );
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                mappingSetName: 'Estate_Intake'
            });

            const button = element.shadowRoot.querySelector('.preview-button');
            button.dispatchEvent(new CustomEvent('click'));
            await flushPromises();
            expect(button.label).toBe('Previewing…');
            expect(button.disabled).toBe(true);

            release({ success: true, plannedChanges: [], findings: [] });
            await flushPromises();
            expect(button.label).toBe('Preview changes');
            expect(button.disabled).toBe(false);
        });

        it('drops a preview response that lands after an edit', async () => {
            let release;
            previewMapping.mockReturnValue(
                new Promise((resolve) => {
                    release = resolve;
                })
            );
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                mappingSetName: 'Estate_Intake'
            });

            clickPreview(element);
            await flushPromises();
            // The reviewer edits while the call is still out
            fireJsonChange(element, { 'First Name': 'Carla', Age: 45 }, true);
            await flushPromises();

            // The stale response arrives — it must not resurrect a diff of
            // JSON that no longer exists
            release({
                success: true,
                plannedChanges: [
                    {
                        objectName: 'Account',
                        fieldName: 'Name',
                        recordId: '001',
                        oldValue: 'Old Co',
                        newValue: 'Stale Co',
                        grade: 'Exact'
                    }
                ],
                findings: []
            });
            await flushPromises();

            expect(
                element.shadowRoot.querySelector('.preview-panel')
            ).toBeNull();
            // And the edit re-enabled the button rather than leaving it stuck
            expect(
                element.shadowRoot.querySelector('.preview-button').disabled
            ).toBe(false);
        });

        it('will not preview a form that is failing validation', async () => {
            const element = buildComponent({
                jsonInput: SAMPLE_JSON,
                mappingSetName: 'Estate_Intake',
                validateTypes: true
            });
            fireJsonChange(element, { Age: 'forty' }, false);
            await flushPromises();

            expect(
                element.shadowRoot.querySelector('.preview-button').disabled
            ).toBe(true);
        });
    });
});
