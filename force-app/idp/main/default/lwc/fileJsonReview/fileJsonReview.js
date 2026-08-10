import { LightningElement, api, wire } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import PDFJS_RESOURCE from '@salesforce/resourceUrl/pdfjs';
import getFileInfo from '@salesforce/apex/FilePreviewController.getFileInfo';
import getFileBase64 from '@salesforce/apex/FilePreviewController.getFileBase64';

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

    fileInfo;
    fileError;
    leftPercent = 50;
    dragging = false;
    pdfFallback = false;
    pdfRendered = false;

    _jsonInput;
    _modifiedJson;
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
        this.dispatchEvent(
            new CustomEvent('jsonchange', { detail: event.detail })
        );
        this.dispatchEvent(
            new FlowAttributeChangeEvent('jsonOutput', this.jsonOutput)
        );
    }

    get submitDisabled() {
        return !this.jsonOutput;
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
