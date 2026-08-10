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

function buildComponent(jsonData, props = {}) {
    const element = createElement('c-json-form', { is: JsonForm });
    Object.assign(element, props);
    element.jsonData = jsonData;
    document.body.appendChild(element);
    return element;
}

// Renaming keys is opt-in, so most label assertions need it switched on
function buildRenamable(jsonData) {
    return buildComponent(jsonData, { editLabels: true });
}

function getValueInputs(element) {
    return [...element.shadowRoot.querySelectorAll('.value-input')];
}

function getLabelInputs(element) {
    return [...element.shadowRoot.querySelectorAll('.label-input')];
}

function getFixedLabels(element) {
    return [...element.shadowRoot.querySelectorAll('.fixed-label')].map(
        (span) => span.textContent
    );
}

function fireChange(input, value) {
    input.value = value;
    input.dispatchEvent(new CustomEvent('change'));
}

function flush() {
    return Promise.resolve();
}

function isModified(input) {
    return input.classList.contains('field-modified');
}

describe('c-json-form', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders a value textbox per primitive field, including array items', () => {
        const element = buildRenamable(SAMPLE);
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
        const element = buildRenamable(SAMPLE);
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
        const element = buildRenamable(SAMPLE);
        const handler = jest.fn();
        element.addEventListener('jsonchange', handler);

        const firstNameLabel = getLabelInputs(element)[0];
        fireChange(firstNameLabel, 'Last Name');

        expect(handler).not.toHaveBeenCalled();
        expect(element.getJson()).toEqual(SAMPLE);
    });

    it('renaming a branch key keeps its children editable', () => {
        const element = buildRenamable(SAMPLE);
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

    it('flags an edited value and clears the flag once it is restored', async () => {
        const element = buildComponent(SAMPLE);
        const firstNameInput = getValueInputs(element)[0];
        expect(isModified(firstNameInput)).toBe(false);

        fireChange(firstNameInput, 'Carla');
        await flush();
        expect(isModified(firstNameInput)).toBe(true);
        // Untouched fields stay unflagged
        expect(isModified(getValueInputs(element)[1])).toBe(false);

        fireChange(firstNameInput, 'Carlos');
        await flush();
        expect(isModified(firstNameInput)).toBe(false);
        expect(element.getJson()).toEqual(SAMPLE);
    });

    it('flags edited numbers and array items', async () => {
        const element = buildComponent(SAMPLE);
        const ageInput = getValueInputs(element)[3];
        const toolInput = getValueInputs(element)[5];

        fireChange(ageInput, '46');
        fireChange(toolInput, 'Drill');
        await flush();
        expect(isModified(ageInput)).toBe(true);
        expect(isModified(toolInput)).toBe(true);

        fireChange(ageInput, '45');
        fireChange(toolInput, 'Hammer');
        await flush();
        expect(isModified(ageInput)).toBe(false);
        expect(isModified(toolInput)).toBe(false);
        expect(element.getJson()).toEqual(SAMPLE);
    });

    it('flags a renamed key and clears the flag once it is renamed back', async () => {
        const element = buildRenamable(SAMPLE);
        const middleNameLabel = getLabelInputs(element)[1];
        expect(isModified(middleNameLabel)).toBe(false);

        fireChange(middleNameLabel, 'Second Name');
        await flush();
        expect(isModified(middleNameLabel)).toBe(true);

        fireChange(middleNameLabel, 'Middle Name');
        await flush();
        expect(isModified(middleNameLabel)).toBe(false);
        expect(element.getJson()).toEqual(SAMPLE);
    });

    it('does not flag a rejected rename', async () => {
        const element = buildRenamable(SAMPLE);
        const firstNameLabel = getLabelInputs(element)[0];

        fireChange(firstNameLabel, 'Last Name');
        await flush();
        expect(isModified(firstNameLabel)).toBe(false);
    });

    it('keeps the flags of separate fields independent', async () => {
        const element = buildComponent(SAMPLE);
        const inputs = getValueInputs(element);

        fireChange(inputs[0], 'Carla');
        fireChange(inputs[2], 'Perez');
        await flush();
        expect(inputs.map(isModified)).toEqual([
            true,
            false,
            true,
            false,
            false,
            false,
            false,
            false
        ]);

        fireChange(inputs[0], 'Carlos');
        await flush();
        expect(isModified(inputs[0])).toBe(false);
        expect(isModified(inputs[2])).toBe(true);
    });

    it('does not clobber a typed value when another field is flagged', async () => {
        const element = buildComponent(SAMPLE);
        const inputs = getValueInputs(element);

        fireChange(inputs[0], 'Carla');
        fireChange(inputs[1], 'Andres');
        await flush();

        expect(inputs[0].value).toBe('Carla');
        expect(inputs[1].value).toBe('Andres');
    });

    it('resets the flags when new JSON is loaded', async () => {
        const element = buildComponent(SAMPLE);
        fireChange(getValueInputs(element)[0], 'Carla');
        await flush();
        expect(isModified(getValueInputs(element)[0])).toBe(true);

        element.jsonData = SAMPLE;
        await flush();
        expect(getValueInputs(element).some(isModified)).toBe(false);
        expect(getLabelInputs(element).some(isModified)).toBe(false);
    });

    it('locks the field names down by default', () => {
        const element = buildComponent(SAMPLE);
        expect(element.editLabels).toBe(false);
        expect(getLabelInputs(element)).toHaveLength(0);
        // Every row keeps its name, now as plain text
        expect(getFixedLabels(element)).toEqual([
            'First Name',
            'Middle Name',
            'Last Name',
            'Age',
            'Born Date',
            'Tools',
            'Item 1',
            'Item 2',
            'Item 3'
        ]);
        // Values stay editable
        expect(getValueInputs(element)).toHaveLength(8);
        fireChange(getValueInputs(element)[0], 'Carla');
        expect(element.getJson()['First Name']).toBe('Carla');
    });

    it('keeps array item labels fixed even when editLabels is on', () => {
        const element = buildRenamable(SAMPLE);
        expect(getFixedLabels(element)).toEqual(['Item 1', 'Item 2', 'Item 3']);
    });

    it('accepts editLabels as the string Flow and App Builder pass', () => {
        const element = buildComponent(SAMPLE, { editLabels: 'true' });
        expect(element.editLabels).toBe(true);
        expect(getLabelInputs(element)).toHaveLength(6);
    });

    it('toggles label editing without losing edits or their flags', async () => {
        const element = buildRenamable(SAMPLE);
        fireChange(getValueInputs(element)[0], 'Carla');
        fireChange(getLabelInputs(element)[1], 'Second Name');
        await flush();

        element.editLabels = false;
        await flush();
        expect(getLabelInputs(element)).toHaveLength(0);
        expect(isModified(getValueInputs(element)[0])).toBe(true);
        expect(element.getJson()['Second Name']).toBe('Arturo');

        element.editLabels = true;
        await flush();
        expect(isModified(getLabelInputs(element)[1])).toBe(true);
        expect(getValueInputs(element)[0].value).toBe('Carla');
    });

    it('shows an empty state when no JSON is provided', () => {
        const element = buildComponent(undefined);
        expect(getValueInputs(element)).toHaveLength(0);
        expect(
            element.shadowRoot.querySelector('.empty-state')
        ).not.toBeNull();
    });
});
