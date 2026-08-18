import { LightningElement } from 'lwc';

const SAMPLE_JSON = {
    'First Name': 'Carlos',
    'Middle Name': 'Arturo',
    'Last Name': 'Gomez',
    Age: 45,
    'Born Date': '1972-10-24T09:00:00.594Z',
    Tools: ['Hammer', 'Handsaw', 'Pliers']
};

const SAMPLE_CONFIDENCE_JSON = {
    'First Name': { value: 'Carlos', confidence: 0.98 },
    'Last Name': { value: 'Gomez', confidence: 0.71 },
    Age: { value: 45, confidence: 0.44 },
    Tools: ['Hammer', 'Handsaw', 'Pliers']
};

export default class JsonFormDemo extends LightningElement {
    sourceJson = JSON.stringify(SAMPLE_JSON, null, 3);
    loadedJson;
    modifiedJson = '';
    parseError = '';

    // Defaults preserve the original demo: labels editable, everything else off.
    editLabels = true;
    editStructure = false;
    collapsible = false;
    searchable = false;
    showConfidence = false;
    validateTypes = false;

    connectedCallback() {
        this.loadSource();
    }

    handleSourceChange(event) {
        this.sourceJson = event.target.value;
    }

    handleLoad() {
        this.loadSource();
    }

    handleLoadConfidenceSample() {
        this.sourceJson = JSON.stringify(SAMPLE_CONFIDENCE_JSON, null, 3);
        this.showConfidence = true;
        this.loadSource();
    }

    handleToggle(event) {
        this[event.target.dataset.flag] = event.target.checked;
    }

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

    handleJsonChange(event) {
        this.modifiedJson = event.detail.jsonString;
    }

    get hasModifiedJson() {
        return this.modifiedJson !== '';
    }
}
