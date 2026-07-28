import { LightningElement } from 'lwc';

const SAMPLE_JSON = {
    'First Name': 'Carlos',
    'Middle Name': 'Arturo',
    'Last Name': 'Gomez',
    Age: 45,
    'Born Date': '1972-10-24T09:00:00.594Z',
    Tools: ['Hammer', 'Handsaw', 'Pliers']
};

export default class JsonFormDemo extends LightningElement {
    sourceJson = JSON.stringify(SAMPLE_JSON, null, 3);
    loadedJson;
    modifiedJson = '';
    parseError = '';

    connectedCallback() {
        this.loadSource();
    }

    handleSourceChange(event) {
        this.sourceJson = event.target.value;
    }

    handleLoad() {
        this.loadSource();
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
