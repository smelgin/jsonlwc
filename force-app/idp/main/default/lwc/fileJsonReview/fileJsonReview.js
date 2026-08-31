import { LightningElement, api, wire } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import PDFJS_RESOURCE from '@salesforce/resourceUrl/pdfjs';
import getFileInfo from '@salesforce/apex/FilePreviewController.getFileInfo';
import getFileBase64 from '@salesforce/apex/FilePreviewController.getFileBase64';
import previewMapping from '@salesforce/apex/IdpMappingController.preview';
import { toPlannedRows, toFindingItems } from 'c/idpResultFormat';

const IMAGE_EXTENSIONS = ['jpg', 'jpeg', 'png', 'gif'];
const MIN_PANE_PERCENT = 20;
const MAX_PANE_PERCENT = 80;
const KEYBOARD_STEP_PERCENT = 2;
// Mirror of FilePreviewController.MAX_PREVIEW_BYTES: above this we skip the
// Apex round-trip and let the browser's native preview handle the file.
const MAX_PDFJS_BYTES = 3 * 1024 * 1024;
// If the viewer iframe never reports ready within this window (e.g. org CSP
// blocks it), give up on PDF.js and use the native preview instead.
const VIEWER_READY_TIMEOUT_MS = 10000;

/**
 * Split-screen review component: a Salesforce file preview on the left and
 * an editable JSON form (c-json-form) on the right. The divider between the
 * panes can be dragged with the mouse or moved with the arrow keys.
 *
 * PDFs are rendered by a bundled PDF.js viewer (the `pdfjs` static resource)
 * running in an iframe. The file bytes are fetched through Apex as base64 and
 * handed to the viewer via postMessage — this keeps everything same-origin
 * and avoids the cross-origin redirect that blocks a direct fetch() of the
 * Files servlet. If PDF.js can't render (viewer error or file too large) the
 * component falls back to the browser's native preview.
 *
 * The editing capabilities of the right-hand pane are the ones c-json-form
 * offers, forwarded one for one and all defaulting to off, so a host that
 * sets none of them gets the plain value-editing form it always got.
 *
 * Given a mapping set name, the pane can also ask the engine what a save
 * would do — IdpMappingController.preview() writes nothing and returns the
 * planned old → new changes, which are listed beside the document so the
 * reviewer confirms them before pressing Save. Leave the mapping set blank
 * and the component never calls the engine at all: it stays the
 * storage-agnostic component it was, emitting `jsonsubmit` for its host to
 * act on.
 */
export default class FileJsonReview extends LightningElement {
    /** Id of the ContentDocument to preview (PDF, JPG, PNG or GIF). */
    @api contentDocumentId;

    /** CSS height of the component, e.g. "600px" or "70vh". */
    @api height = '600px';

    /** Label of the button that returns the modified JSON. */
    @api submitLabel = 'Save';

    /**
     * Whether the reviewer may rename the JSON's field names as well as edit
     * its values. Passed straight through to c-json-form, which owns the
     * default (off) and the coercion of the string Flow hands over.
     */
    @api editLabels;

    /**
     * The rest of c-json-form's opt-in capabilities, forwarded untouched.
     * The child owns their defaults and the string-to-boolean coercion Flow
     * and App Builder need, so there is nothing to do here but pass them on.
     */
    @api editStructure;
    @api collapsible;
    @api searchable;
    @api showConfidence;
    @api confidenceThreshold;
    @api validateTypes;

    /**
     * DeveloperName of the IDP_Mapping_Set__mdt to preview against. Blank
     * (the default) hides the Preview button and keeps the component free of
     * any call to the mapping engine.
     */
    @api mappingSetName;

    fileInfo;
    fileError;
    leftPercent = 50;
    dragging = false;
    pdfFallback = false;
    pdfRendered = false;

    previewing = false;
    previewResult;
    previewError;
    // Ticket for the in-flight preview call. Bumped by every new request
    // and by clearPreview(), so a response landing after an edit (or after
    // a newer request) identifies itself as stale and is dropped.
    _previewSeq = 0;

    _jsonInput;
    _modifiedJson;
    // c-json-form reports validity on every edit; until it does, and whenever
    // type validation is switched off, there is nothing to block a save.
    _formValid = true;
    _onDragMove;
    _onDragEnd;
    _onMessage;
    _pdfBase64;
    _viewerReady = false;
    _viewerOrigin;
    _viewerTimeout;

    /** The JSON string to edit in the right pane. */
    @api
    get jsonInput() {
        return this._jsonInput;
    }
    set jsonInput(value) {
        this._jsonInput = value;
        this._modifiedJson = undefined;
        this._formValid = true;
        this.clearPreview();
    }

    /** The JSON string including the user's edits. Flow output attribute. */
    @api
    get jsonOutput() {
        return this._modifiedJson !== undefined
            ? this._modifiedJson
            : this._jsonInput || '';
    }

    connectedCallback() {
        this._onMessage = this.handleViewerMessage.bind(this);
        window.addEventListener('message', this._onMessage);
    }

    disconnectedCallback() {
        this.stopDrag();
        this.clearViewerTimeout();
        if (this._onMessage) {
            window.removeEventListener('message', this._onMessage);
            this._onMessage = undefined;
        }
    }

    @wire(getFileInfo, { contentDocumentId: '$contentDocumentId' })
    wiredFile({ data, error }) {
        if (data) {
            this.fileInfo = data;
            this.fileError = undefined;
            if (data.fileExtension === 'pdf') {
                this.preparePdf();
            }
        } else if (error) {
            this.fileInfo = undefined;
            this.fileError =
                (error.body && error.body.message) || 'Unable to load file.';
        }
    }

    // ---------------------------------------------------------------------
    // File preview
    // ---------------------------------------------------------------------

    /**
     * URL of the file on the standard Files servlet. Used for images and for
     * the native PDF fallback: an iframe/img follows the servlet's
     * cross-origin redirect natively (a fetch() would be blocked by CORS).
     */
    get previewUrl() {
        return `/sfc/servlet.shepherd/version/download/${this.fileInfo.contentVersionId}`;
    }

    /** URL of the bundled PDF.js viewer, cache-busted per file so the iframe
     *  reloads and re-runs its ready handshake for each new document. */
    get pdfViewerUrl() {
        return `${PDFJS_RESOURCE}/viewer.html?v=${this.fileInfo.contentVersionId}`;
    }

    get isImage() {
        return IMAGE_EXTENSIONS.includes(this.fileInfo.fileExtension);
    }

    get isPdf() {
        return this.fileInfo.fileExtension === 'pdf';
    }

    get isUnsupported() {
        return !this.isImage && !this.isPdf;
    }

    get hasNoDocument() {
        return !this.contentDocumentId;
    }

    get isLoading() {
        return !this.hasNoDocument && !this.fileInfo && !this.fileError;
    }

    get pdfLoading() {
        return this.isPdf && !this.pdfFallback && !this.pdfRendered;
    }

    /**
     * Fetches the PDF bytes through Apex and, once the viewer iframe reports
     * ready, hands them over. Oversized files and any Apex error drop to the
     * native preview instead.
     */
    preparePdf() {
        this.pdfFallback = false;
        this.pdfRendered = false;
        this._viewerReady = false;
        this._pdfBase64 = undefined;
        this.clearViewerTimeout();

        if (this.fileInfo.contentSize > MAX_PDFJS_BYTES) {
            this.pdfFallback = true;
            return;
        }
        // Cleared on ready/error/disconnect (see clearViewerTimeout).
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._viewerTimeout = setTimeout(() => {
            if (!this._viewerReady) {
                this.pdfFallback = true;
            }
        }, VIEWER_READY_TIMEOUT_MS);

        getFileBase64({ contentVersionId: this.fileInfo.contentVersionId })
            .then((base64) => {
                this._pdfBase64 = base64;
                this.sendToViewer();
            })
            .catch(() => {
                this.clearViewerTimeout();
                this.pdfFallback = true;
            });
    }

    clearViewerTimeout() {
        if (this._viewerTimeout) {
            clearTimeout(this._viewerTimeout);
            this._viewerTimeout = undefined;
        }
    }

    handleViewerMessage(event) {
        const frame = this.refs.pdfFrame;
        if (!frame || event.source !== frame.contentWindow) {
            return;
        }
        const message = event.data;
        if (!message || typeof message.type !== 'string') {
            return;
        }
        if (message.type === 'pdfjs-ready') {
            this._viewerReady = true;
            this._viewerOrigin = event.origin;
            this.clearViewerTimeout();
            this.sendToViewer();
        } else if (message.type === 'pdfjs-rendered') {
            this.pdfRendered = true;
        } else if (message.type === 'pdfjs-error') {
            this.pdfFallback = true;
        }
    }

    sendToViewer() {
        const frame = this.refs.pdfFrame;
        if (this._viewerReady && this._pdfBase64 && frame) {
            frame.contentWindow.postMessage(
                { type: 'pdfjs-render', data: this._pdfBase64 },
                this._viewerOrigin || '*'
            );
        }
    }

    // ---------------------------------------------------------------------
    // Split pane sizing
    // ---------------------------------------------------------------------

    get containerStyle() {
        return `height: ${this.height};`;
    }

    get containerClass() {
        return this.dragging
            ? 'split-container split-container_dragging'
            : 'split-container';
    }

    get leftPaneStyle() {
        return `width: ${this.leftPercent}%;`;
    }

    get leftPercentRounded() {
        return Math.round(this.leftPercent);
    }

    handleDividerPointerDown(event) {
        event.preventDefault();
        this.dragging = true;
        this._onDragMove = (moveEvent) => this.resizeTo(moveEvent.clientX);
        this._onDragEnd = () => this.stopDrag();
        window.addEventListener('pointermove', this._onDragMove);
        window.addEventListener('pointerup', this._onDragEnd);
    }

    handleDividerKeyDown(event) {
        if (event.key === 'ArrowLeft') {
            this.setLeftPercent(this.leftPercent - KEYBOARD_STEP_PERCENT);
        } else if (event.key === 'ArrowRight') {
            this.setLeftPercent(this.leftPercent + KEYBOARD_STEP_PERCENT);
        }
    }

    resizeTo(clientX) {
        const rect = this.refs.container.getBoundingClientRect();
        if (rect.width > 0) {
            this.setLeftPercent(((clientX - rect.left) / rect.width) * 100);
        }
    }

    setLeftPercent(value) {
        this.leftPercent = Math.min(
            MAX_PANE_PERCENT,
            Math.max(MIN_PANE_PERCENT, value)
        );
    }

    stopDrag() {
        this.dragging = false;
        if (this._onDragMove) {
            window.removeEventListener('pointermove', this._onDragMove);
            window.removeEventListener('pointerup', this._onDragEnd);
            this._onDragMove = undefined;
            this._onDragEnd = undefined;
        }
    }

    // ---------------------------------------------------------------------
    // JSON form plumbing
    // ---------------------------------------------------------------------

    handleJsonChange(event) {
        this._modifiedJson = JSON.stringify(event.detail.value);
        // `valid` is false only when the form is validating types and some
        // field no longer parses as the one it loaded as.
        this._formValid = event.detail.valid !== false;
        // Any edit invalidates a preview taken before it.
        this.clearPreview();
        this.dispatchEvent(
            new CustomEvent('jsonchange', { detail: event.detail })
        );
        this.dispatchEvent(
            new FlowAttributeChangeEvent('jsonOutput', this.jsonOutput)
        );
    }

    get submitDisabled() {
        return !this.jsonOutput || !this._formValid || this.previewing;
    }

    /** Shown next to a disabled Save so the reason is not a mystery. */
    get blockedMessage() {
        return this._formValid
            ? undefined
            : 'Fix the highlighted fields first.';
    }

    // ---------------------------------------------------------------------
    // Preview
    // ---------------------------------------------------------------------

    /** The Preview button only exists once a host names a mapping set. */
    get canPreview() {
        return Boolean(this.mappingSetName) && Boolean(this.jsonOutput);
    }

    get previewDisabled() {
        return this.previewing || !this._formValid;
    }

    get hasPreview() {
        return Boolean(this.previewResult) || Boolean(this.previewError);
    }

    /** Labels the button with what it is doing while it is doing it. */
    get previewLabel() {
        return this.previewing ? 'Previewing…' : 'Preview changes';
    }

    /**
     * Asks the engine what a save would change, without writing anything:
     * Preview mode runs the whole extraction pipeline and skips the DML.
     *
     * The reviewer can keep editing while the call is out, and every edit
     * calls clearPreview(). The sequence ticket makes sure a response that
     * comes back after that — or after a newer Preview click — is thrown
     * away instead of resurrecting a diff of JSON that no longer exists.
     */
    handlePreview() {
        const ticket = ++this._previewSeq;
        this.previewing = true;
        this.previewResult = undefined;
        this.previewError = undefined;
        previewMapping({
            contentDocumentId: this.contentDocumentId,
            jsonString: this.jsonOutput,
            mappingSetName: this.mappingSetName
        })
            .then((result) => {
                if (ticket === this._previewSeq) {
                    this.previewResult = result;
                }
            })
            .catch((error) => {
                if (ticket === this._previewSeq) {
                    this.previewError =
                        (error.body && error.body.message) ||
                        'The preview could not be produced.';
                }
            })
            .finally(() => {
                if (ticket === this._previewSeq) {
                    this.previewing = false;
                }
            });
    }

    handleDismissPreview() {
        this.clearPreview();
    }

    clearPreview() {
        this._previewSeq++;
        this.previewing = false;
        this.previewResult = undefined;
        this.previewError = undefined;
    }

    /** One row per planned field write, old → new (c/idpResultFormat). */
    get plannedRows() {
        return toPlannedRows(this.previewResult);
    }

    get hasPlannedRows() {
        return this.plannedRows.length > 0;
    }

    /** Anything the run wants the reviewer to know; Info is left out because
     *  an unmatched row is data, not a problem to act on here. */
    get previewFindings() {
        return toFindingItems(this.previewResult);
    }

    get hasPreviewFindings() {
        return this.previewFindings.length > 0;
    }

    get previewSummary() {
        if (!this.previewResult) {
            return '';
        }
        const count = this.plannedRows.length;
        if (count === 0) {
            return 'This document would change nothing.';
        }
        return `${count} field${count === 1 ? '' : 's'} would change. Nothing has been written yet.`;
    }

    /**
     * Returns the current form contents so the host can persist them.
     * Emits a `jsonsubmit` event (detail.value is the object, detail.jsonString
     * the string) for parent components, and refreshes the jsonOutput Flow
     * attribute so a Screen Flow / OmniScript reads the latest value.
     */
    handleSubmit() {
        const form = this.refs.jsonForm;
        const value = form ? form.getJson() : undefined;
        const jsonString = this.jsonOutput;
        this.dispatchEvent(
            new CustomEvent('jsonsubmit', { detail: { value, jsonString } })
        );
        this.dispatchEvent(
            new FlowAttributeChangeEvent('jsonOutput', jsonString)
        );
    }
}
