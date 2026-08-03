import { createElement } from 'lwc';
import JsonForm from 'c/jsonForm';

const SAMPLE = {
    'First Name': 'Carlos',
    'Middle Name': 'Arturo',
    'Last Name': 'Gomez',
    Age: 45,
    'Born Date': '1972-10-24T09:00:00.594Z',
    Tools: ['Hammer', 'Handsaw', 'Pliers']
};

function buildComponent(jsonData) {
    const element = createElement('c-json-form', { is: JsonForm });
    element.jsonData = jsonData;
    document.body.appendChild(element);
    return element;
}

function getValueInputs(element) {
    return [...element.shadowRoot.querySelectorAll('.value-input')];
}

function getLabelInputs(element) {
    return [...element.shadowRoot.querySelectorAll('.label-input')];
}

function fireChange(input, value) {
    input.value = value;
    input.dispatchEvent(new CustomEvent('change'));
}

describe('c-json-form', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders a value textbox per primitive field, including array items', () => {
        const element = buildComponent(SAMPLE);
        // 5 top-level primitives + 3 array items
        expect(getValueInputs(element)).toHaveLength(8);
        // Editable labels only for object keys (5 primitives + Tools branch)
        expect(getLabelInputs(element)).toHaveLength(6);
    });

    it('accepts a JSON string as input', () => {
        const element = buildComponent(JSON.stringify(SAMPLE));
        expect(getValueInputs(element)).toHaveLength(8);
        expect(element.getJson()).toEqual(SAMPLE);
    });

    it('emits modified JSON when a value changes and keeps number types', () => {
        const element = buildComponent(SAMPLE);
        const handler = jest.fn();
        element.addEventListener('jsonchange', handler);

        const ageInput = getValueInputs(element)[3];
        fireChange(ageInput, '46');

        expect(handler).toHaveBeenCalledTimes(1);
        const detail = handler.mock.calls[0][0].detail;
        expect(detail.value.Age).toBe(46);
        expect(element.getJson().Age).toBe(46);
    });

    it('updates array items', () => {
        const element = buildComponent(SAMPLE);
        const toolInput = getValueInputs(element)[5]; // first Tools item
        fireChange(toolInput, 'Drill');
        expect(element.getJson().Tools).toEqual([
            'Drill',
            'Handsaw',
            'Pliers'
        ]);
    });

    it('renames keys while preserving key order', () => {
        const element = buildComponent(SAMPLE);
        const handler = jest.fn();
        element.addEventListener('jsonchange', handler);

        const middleNameLabel = getLabelInputs(element)[1];
        fireChange(middleNameLabel, 'Second Name');

        expect(handler).toHaveBeenCalledTimes(1);
        const result = element.getJson();
        expect(result['Second Name']).toBe('Arturo');
        expect(result['Middle Name']).toBeUndefined();
        expect(Object.keys(result)).toEqual([
            'First Name',
            'Second Name',
            'Last Name',
            'Age',
            'Born Date',
            'Tools'
        ]);
    });

    it('rejects a rename to an existing key', () => {
        const element = buildComponent(SAMPLE);
        const handler = jest.fn();
        element.addEventListener('jsonchange', handler);

        const firstNameLabel = getLabelInputs(element)[0];
        fireChange(firstNameLabel, 'Last Name');

        expect(handler).not.toHaveBeenCalled();
        expect(element.getJson()).toEqual(SAMPLE);
    });

    it('renaming a branch key keeps its children editable', () => {
        const element = buildComponent(SAMPLE);
        const toolsLabel = getLabelInputs(element)[5];
        fireChange(toolsLabel, 'Equipment');

        const toolInput = getValueInputs(element)[5];
        fireChange(toolInput, 'Drill');

        const result = element.getJson();
        expect(result.Equipment).toEqual(['Drill', 'Handsaw', 'Pliers']);
        expect(result.Tools).toBeUndefined();
    });

    it('handles nested objects', () => {
        const element = buildComponent({
            Person: { Address: { City: 'Bogota' }, Active: true }
        });
        const inputs = getValueInputs(element);
        expect(inputs).toHaveLength(2);

        fireChange(inputs[0], 'Medellin');
        fireChange(inputs[1], 'false');

        const result = element.getJson();
        expect(result.Person.Address.City).toBe('Medellin');
        expect(result.Person.Active).toBe(false);
    });

    it('accepts JSON through the jsonInput string property (Flow/App Builder)', () => {
        const element = createElement('c-json-form', { is: JsonForm });
        element.jsonInput = JSON.stringify(SAMPLE);
        document.body.appendChild(element);

        expect(getValueInputs(element)).toHaveLength(8);
        expect(JSON.parse(element.jsonOutput)).toEqual(SAMPLE);
    });

    it('updates jsonOutput and fires a FlowAttributeChangeEvent on edit', () => {
        const element = createElement('c-json-form', { is: JsonForm });
        element.jsonInput = JSON.stringify(SAMPLE);
        document.body.appendChild(element);

        const flowHandler = jest.fn();
        element.addEventListener('lightning__flowattributechange', flowHandler);

        fireChange(getValueInputs(element)[3], '46');

        // The sfdx-lwc-jest stub drops the event payload, so assert the
        // event fired and check the value through the jsonOutput property.
        expect(flowHandler).toHaveBeenCalledTimes(1);
        expect(JSON.parse(element.jsonOutput).Age).toBe(46);
    });

    it('shows an empty state when no JSON is provided', () => {
        const element = buildComponent(undefined);
        expect(getValueInputs(element)).toHaveLength(0);
        expect(
            element.shadowRoot.querySelector('.empty-state')
        ).not.toBeNull();
    });
});
