import { LightningElement, api, wire } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import PDFJS_RESOURCE from '@salesforce/resourceUrl/pdfjs';
import getFileInfo from '@salesforce/apex/FilePreviewController.getFileInfo';
import getFileBase64 from '@salesforce/apex/FilePreviewController.getFileBase64';
import previewMapping from '@salesforce/apex/IdpMappingController.preview';
import { toPlannedRows, toFindingItems } from 'c/idpResultFormat';

/** File extensions the left pane renders as an image. */
const IMAGE_EXTENSIONS = ['jpg', 'jpeg', 'png', 'gif'];

/** Narrowest the left pane may be dragged. */
const MIN_PANE_PERCENT = 20;

/** Widest the left pane may be dragged. */
const MAX_PANE_PERCENT = 80;

/** How far one arrow-key press moves the divider. */
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
 *
 * @module fileJsonReview
 * @extends LightningElement
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

    // The rest of c-json-form's opt-in capabilities are forwarded untouched.
    // The child owns their defaults and the string-to-boolean coercion Flow
    // and App Builder need, so there is nothing to do here but pass them on.

    /** Whether the reviewer may add, nest or remove fields. */
    @api editStructure;

    /** Whether groups can be collapsed. */
    @api collapsible;

    /** Whether the search box is shown. */
    @api searchable;

    /** Whether OCR confidence is surfaced per field. */
    @api showConfidence;

    /** Confidence below which a field is flagged to the reviewer. */
    @api confidenceThreshold;

    /** Whether values are checked against the type they loaded as. */
    @api validateTypes;

    /**
     * DeveloperName of the IDP_Mapping_Set__mdt to preview against. Blank
     * (the default) hides the Preview button and keeps the component free of
     * any call to the mapping engine.
     */
    @api mappingSetName;

    /** Metadata of the file being previewed. */
    fileInfo;

    /** Why the file could not be loaded. */
    fileError;

    /** Width of the left pane, as a percentage of the container. */
    leftPercent = 50;

    /** Whether the divider is being dragged. */
    dragging = false;

    /** Whether PDF.js gave up and the native preview took over. */
    pdfFallback = false;

    /** Whether the bundled viewer has painted a page. */
    pdfRendered = false;

    /** Whether a preview call is in flight. */
    previewing = false;

    /** Result of the most recent preview. */
    previewResult;

    /** Why the most recent preview could not be produced. */
    previewError;
    // Ticket for the in-flight preview call. Bumped by every new request
    // and by clearPreview(), so a response landing after an edit (or after
    // a newer request) identifies itself as stale and is dropped.
    _previewSeq = 0;

    /** Document as the host supplied it. */
    _jsonInput;

    /** Document as the reviewer has edited it. */
    _modifiedJson;
    // c-json-form reports validity on every edit; until it does, and whenever
    // type validation is switched off, there is nothing to block a save.
    _formValid = true;
    /** Pointer-move listener held while a drag is in progress. */
    _onDragMove;

    /** Pointer-up listener held while a drag is in progress. */
    _onDragEnd;

    /** Window message listener for the viewer handshake. */
    _onMessage;

    /** File bytes waiting for the viewer to report ready. */
    _pdfBase64;

    /** Whether the viewer iframe has completed its handshake. */
    _viewerReady = false;

    /** Origin the viewer answered from, used when posting to it. */
    _viewerOrigin;

    /** Handle of the viewer readiness timeout. */
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

    /**
     * Starts listening for the PDF.js viewer's handshake.
     */
    connectedCallback() {
        this._onMessage = this.handleViewerMessage.bind(this);
        window.addEventListener('message', this._onMessage);
    }

    /**
     * Releases the drag and message listeners and the pending timeout.
     */
    disconnectedCallback() {
        this.stopDrag();
        this.clearViewerTimeout();
        if (this._onMessage) {
            window.removeEventListener('message', this._onMessage);
            this._onMessage = undefined;
        }
    }

    /**
     * Wired file metadata; a PDF starts loading its bytes straight away.
     *
     * @param {{data:any,error:any}} response Wire adapter payload.
     */
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

    /** Whether the file renders as an image. */
    get isImage() {
        return IMAGE_EXTENSIONS.includes(this.fileInfo.fileExtension);
    }

    /** Whether the file renders as a PDF. */
    get isPdf() {
        return this.fileInfo.fileExtension === 'pdf';
    }

    /** Whether the file is of a kind this pane cannot show. */
    get isUnsupported() {
        return !this.isImage && !this.isPdf;
    }

    /** Whether the host named no file at all. */
    get hasNoDocument() {
        return !this.contentDocumentId;
    }

    /** Whether the file metadata is still on its way. */
    get isLoading() {
        return !this.hasNoDocument && !this.fileInfo && !this.fileError;
    }

    /** Whether PDF.js is still working towards a first page. */
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

    /**
     * Cancels the viewer readiness deadline.
     */
    clearViewerTimeout() {
        if (this._viewerTimeout) {
            clearTimeout(this._viewerTimeout);
            this._viewerTimeout = undefined;
        }
    }

    /**
     * Handles a message from the viewer iframe.
     *
     * Messages from anything but this component's own frame are ignored.
     *
     * @param {MessageEvent} event Message posted by the viewer.
     */
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

    /**
     * Hands the file bytes to the viewer, once both are ready.
     */
    sendToViewer() {
        const frame = this.refs.pdfFrame;
        if (this._viewerReady && this._pdfBase64 && frame) {
            frame.contentWindow.postMessage(
                { type: 'pdfjs-render', data: this._pdfBase64 },
                this._viewerOrigin || '*'
            );
        }
    }

    /** Inline height the host asked for. */
    get containerStyle() {
        return `height: ${this.height};`;
    }

    /** Container classes, marking the container while a drag is active. */
    get containerClass() {
        return this.dragging
            ? 'split-container split-container_dragging'
            : 'split-container';
    }

    /** Inline width of the left pane. */
    get leftPaneStyle() {
        return `width: ${this.leftPercent}%;`;
    }

    /** Left pane width as a whole number, for the divider's ARIA value. */
    get leftPercentRounded() {
        return Math.round(this.leftPercent);
    }

    /**
     * Starts a divider drag and listens for the pointer at window level, so
     * the drag survives the pointer leaving the divider.
     *
     * @param {PointerEvent} event Pointer-down event on the divider.
     */
    handleDividerPointerDown(event) {
        event.preventDefault();
        this.dragging = true;
        this._onDragMove = (moveEvent) => this.resizeTo(moveEvent.clientX);
        this._onDragEnd = () => this.stopDrag();
        window.addEventListener('pointermove', this._onDragMove);
        window.addEventListener('pointerup', this._onDragEnd);
    }

    /**
     * Moves the divider with the arrow keys.
     *
     * @param {KeyboardEvent} event Key-down event on the divider.
     */
    handleDividerKeyDown(event) {
        if (event.key === 'ArrowLeft') {
            this.setLeftPercent(this.leftPercent - KEYBOARD_STEP_PERCENT);
        } else if (event.key === 'ArrowRight') {
            this.setLeftPercent(this.leftPercent + KEYBOARD_STEP_PERCENT);
        }
    }

    /**
     * Places the divider under the pointer.
     *
     * @param {number} clientX Pointer position in viewport coordinates.
     */
    resizeTo(clientX) {
        const rect = this.refs.container.getBoundingClientRect();
        if (rect.width > 0) {
            this.setLeftPercent(((clientX - rect.left) / rect.width) * 100);
        }
    }

    /**
     * Sets the left pane width, holding it within the allowed range.
     *
     * @param {number} value Requested width as a percentage.
     */
    setLeftPercent(value) {
        this.leftPercent = Math.min(
            MAX_PANE_PERCENT,
            Math.max(MIN_PANE_PERCENT, value)
        );
    }

    /**
     * Ends a divider drag and releases its listeners.
     */
    stopDrag() {
        this.dragging = false;
        if (this._onDragMove) {
            window.removeEventListener('pointermove', this._onDragMove);
            window.removeEventListener('pointerup', this._onDragEnd);
            this._onDragMove = undefined;
            this._onDragEnd = undefined;
        }
    }

    /**
     * Handles an edit in the JSON form.
     *
     * Re-emits the change for the host, refreshes the Flow output attribute
     * and drops any preview taken before the edit.
     *
     * @param {CustomEvent} event Change event from c-json-form.
     */
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

    /** Whether Save is blocked, by invalid fields or a preview in flight. */
    get submitDisabled() {
        return !this.jsonOutput || !this._formValid || this.previewing;
    }

    /** Shown next to a disabled Save so the reason is not a mystery. */
    get blockedMessage() {
        return this._formValid
            ? undefined
            : 'Fix the highlighted fields first.';
    }

    /** The Preview button only exists once a host names a mapping set. */
    get canPreview() {
        return Boolean(this.mappingSetName) && Boolean(this.jsonOutput);
    }

    /** Whether Preview is blocked, by invalid fields or a call in flight. */
    get previewDisabled() {
        return this.previewing || !this._formValid;
    }

    /** Whether a preview result or error is available to show. */
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

    /**
     * Closes the preview panel at the reviewer's request.
     */
    handleDismissPreview() {
        this.clearPreview();
    }

    /**
     * Drops the preview and invalidates any response still in flight.
     */
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

    /** Whether the preview planned any field writes. */
    get hasPlannedRows() {
        return this.plannedRows.length > 0;
    }

    /** Anything the run wants the reviewer to know; Info is left out because
     *  an unmatched row is data, not a problem to act on here. */
    get previewFindings() {
        return toFindingItems(this.previewResult);
    }

    /** Whether the preview raised anything worth reading. */
    get hasPreviewFindings() {
        return this.previewFindings.length > 0;
    }

    /** One line describing what a save would change. */
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
     * Hands the reviewed document to the host to persist.
     *
     * Emits `jsonsubmit` — detail.value is the object, detail.jsonString the
     * string — for parent components, and refreshes the jsonOutput Flow
     * attribute so a Screen Flow or OmniScript reads the latest value.
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
