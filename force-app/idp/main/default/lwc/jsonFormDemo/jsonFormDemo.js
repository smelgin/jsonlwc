import { LightningElement } from 'lwc';

/** Plain document showing the ordinary field types. */
const SAMPLE_JSON = {
    'First Name': 'Carlos',
    'Middle Name': 'Arturo',
    'Last Name': 'Gomez',
    Age: 45,
    'Born Date': '1972-10-24T09:00:00.594Z',
    Tools: ['Hammer', 'Handsaw', 'Pliers']
};

/** Document whose fields carry OCR confidence envelopes. */
const SAMPLE_CONFIDENCE_JSON = {
    'First Name': { value: 'Carlos', confidence: 0.98 },
    'Last Name': { value: 'Gomez', confidence: 0.71 },
    Age: { value: 45, confidence: 0.44 },
    Tools: ['Hammer', 'Handsaw', 'Pliers']
};

/**
 * Document where one field holds two facts, the case JF-13 exists for:
 * convert "Executor" into a group and split the name and the ID into
 * children.
 */
const SAMPLE_NESTING_JSON = {
    'Estate Number': '004521/2024',
    Executor: 'BONGIWE PAMELA FELICIA MONKWE - 0203210284089 (ID)',
    Deceased: 'JOHANNES PETRUS VAN DER MERWE - 4501015009087 (ID)'
};

/**
 * LWC that exercises c-json-form against editable sample documents, with
 * every feature flag exposed as a toggle.
 *
 * @module jsonFormDemo
 * @extends LightningElement
 */
export default class JsonFormDemo extends LightningElement {
    /** Document text in the editor, before it is parsed. */
    sourceJson = JSON.stringify(SAMPLE_JSON, null, 3);
    /** Parsed document handed to the form. */
    loadedJson;
    /** JSON the form last emitted, empty until the user edits. */
    modifiedJson = '';
    /** Why the editor text could not be parsed. */
    parseError = '';

    // Defaults preserve the original demo: labels editable, everything else off.

    /** Whether field labels can be renamed. */
    editLabels = true;
    /** Whether fields can be added, nested or removed. */
    editStructure = false;
    /** Whether groups can be collapsed. */
    collapsible = false;
    /** Whether the search box is shown. */
    searchable = false;
    /** Whether OCR confidence is surfaced per field. */
    showConfidence = false;
    /** Whether values are checked against their inferred type. */
    validateTypes = false;

    /**
     * Parses the initial sample so the form has something to render.
     */
    connectedCallback() {
        this.loadSource();
    }

    /**
     * Tracks edits to the source text without parsing them yet.
     *
     * @param {Event} event Change event from the textarea.
     */
    handleSourceChange(event) {
        this.sourceJson = event.target.value;
    }

    /**
     * Parses whatever the editor currently holds.
     */
    handleLoad() {
        this.loadSource();
    }

    /**
     * Loads the nesting sample and turns structural editing on, since that
     * is the feature the sample exists to show.
     */
    handleLoadNestingSample() {
        this.sourceJson = JSON.stringify(SAMPLE_NESTING_JSON, null, 3);
        this.editStructure = true;
        this.loadSource();
    }

    /**
     * Loads the confidence sample and turns the confidence display on.
     */
    handleLoadConfidenceSample() {
        this.sourceJson = JSON.stringify(SAMPLE_CONFIDENCE_JSON, null, 3);
        this.showConfidence = true;
        this.loadSource();
    }

    /**
     * Applies one feature toggle, named by the checkbox's data-flag.
     *
     * @param {Event} event Change event from a checkbox.
     */
    handleToggle(event) {
        this[event.target.dataset.flag] = event.target.checked;
    }

    /**
     * Parses the source text, reporting a syntax error rather than
     * replacing the document the form is already showing.
     */
    loadSource() {
        try {
            const parsed = JSON.parse(this.sourceJson);
            this.parseError = '';
            this.modifiedJson = '';
            this.loadedJson = parsed;
        } catch (e) {
            this.parseError = `Invalid JSON: ${e.message}`;
        }
    }

    /**
     * Keeps the JSON the form emitted, so the demo can show it back.
     *
     * @param {CustomEvent} event Change event from c-json-form.
     */
    handleJsonChange(event) {
        this.modifiedJson = event.detail.jsonString;
    }

    /** Whether the form has emitted anything yet. */
    get hasModifiedJson() {
        return this.modifiedJson !== '';
    }
}
