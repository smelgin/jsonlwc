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

// --- helpers for the opt-in features ---------------------------------

function buildStructural(jsonData) {
    return buildComponent(jsonData, { editStructure: true });
}

function queryAll(element, selector) {
    return [...element.shadowRoot.querySelectorAll(selector)];
}

/** The data-id of the row whose fixed label is `label`. */
function rowIdFor(element, label) {
    const row = queryAll(element, '.form-row').find((candidate) => {
        const span = candidate.querySelector('.fixed-label');
        return span && span.textContent === label;
    });
    return row ? row.querySelector('[data-id]').dataset.id : undefined;
}

function branchRowId(element, label) {
    return rowIdFor(element, label);
}

function clickDeleteFor(element, label) {
    const id = rowIdFor(element, label);
    const button = queryAll(element, '.delete-button').find(
        (candidate) => candidate.dataset.id === id
    );
    button.dispatchEvent(new CustomEvent('click'));
}

function clickButtonLabelled(element, label) {
    const button = queryAll(element, 'lightning-button').find(
        (candidate) => candidate.label === label
    );
    button.dispatchEvent(new CustomEvent('click'));
}

async function openRootAddForm(element) {
    element.shadowRoot
        .querySelector('.add-root-button')
        .dispatchEvent(new CustomEvent('click'));
    await flush();
}

async function openAddFormOn(element, rowId) {
    const button = queryAll(element, '.add-button').find(
        (candidate) => candidate.dataset.id === rowId
    );
    button.dispatchEvent(new CustomEvent('click'));
    await flush();
}

function setAddName(element, name) {
    const input = element.shadowRoot.querySelector('.add-form .add-name');
    input.value = name;
    input.dispatchEvent(new CustomEvent('change'));
}

function setAddType(element, type) {
    element.shadowRoot
        .querySelector('.add-form .add-type')
        .dispatchEvent(new CustomEvent('change', { detail: { value: type } }));
}

function clickConfirmAdd(element) {
    element.shadowRoot
        .querySelector('.add-form .add-confirm')
        .dispatchEvent(new CustomEvent('click'));
}

/** Opens the add form (root when rowId is null), fills it in, confirms. */
async function addField(element, rowId, name, type) {
    if (rowId === null) {
        await openRootAddForm(element);
    } else {
        await openAddFormOn(element, rowId);
    }
    if (name !== undefined && name !== null) {
        setAddName(element, name);
    }
    if (type) {
        setAddType(element, type);
    }
    clickConfirmAdd(element);
    await flush();
}

/** The value textbox belonging to the row labelled `label`. */
function valueInputFor(element, label) {
    const id = rowIdFor(element, label);
    return queryAll(element, '.value-input').find(
        (input) => input.dataset.id === id
    );
}

function setAddContainer(element, kind) {
    element.shadowRoot
        .querySelector('.add-form .add-container')
        .dispatchEvent(new CustomEvent('change', { detail: { value: kind } }));
}

/** Opens the add form on the row labelled `label` and confirms it. When the
 *  row is a leaf this is the JF-13 conversion path. */
async function addChildTo(element, label, options = {}) {
    await openAddFormOn(element, rowIdFor(element, label));
    if (options.container) {
        setAddContainer(element, options.container);
        await flush();
    }
    if (options.name !== undefined && options.name !== null) {
        setAddName(element, options.name);
    }
    if (options.type) {
        setAddType(element, options.type);
    }
    clickConfirmAdd(element);
    await flush();
}

async function search(element, term) {
    const input = element.shadowRoot.querySelector('.search-input');
    input.value = term;
    input.dispatchEvent(new CustomEvent('change'));
    await flush();
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
        expect(element.getJson().Tools).toEqual(['Drill', 'Handsaw', 'Pliers']);
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
        expect(element.shadowRoot.querySelector('.empty-state')).not.toBeNull();
    });

    // -----------------------------------------------------------------
    // editStructure — adding and deleting
    // -----------------------------------------------------------------

    describe('editStructure', () => {
        it('is off by default, so no add or delete controls render', () => {
            const element = buildComponent(SAMPLE);
            expect(element.editStructure).toBe(false);
            expect(queryAll(element, '.delete-button')).toHaveLength(0);
            expect(queryAll(element, '.add-button')).toHaveLength(0);
            expect(
                element.shadowRoot.querySelector('.add-root-button')
            ).toBeNull();
        });

        it('adds a named text field to the root object', async () => {
            const element = buildStructural(SAMPLE);
            const handler = jest.fn();
            element.addEventListener('jsonchange', handler);

            await addField(element, null, 'Nickname', 'string');

            expect(handler).toHaveBeenCalledTimes(1);
            const result = element.getJson();
            expect(result.Nickname).toBe('');
            // Appended, so the original key order is untouched
            expect(Object.keys(result)).toEqual([
                ...Object.keys(SAMPLE),
                'Nickname'
            ]);
        });

        it('adds fields of each type with a sensible starting value', async () => {
            const element = buildStructural({ Root: 'x' });
            await addField(element, null, 'Count', 'number');
            await addField(element, null, 'Active', 'boolean');
            await addField(element, null, 'Blank', 'null');
            await addField(element, null, 'Group', 'object');
            await addField(element, null, 'List', 'array');

            expect(element.getJson()).toEqual({
                Root: 'x',
                Count: 0,
                Active: false,
                Blank: null,
                Group: {},
                List: []
            });
        });

        it('flags a newly added field as modified', async () => {
            const element = buildStructural(SAMPLE);
            await addField(element, null, 'Nickname', 'string');

            const labels = getFixedLabels(element);
            expect(labels).toContain('Nickname');
            // The new field's value box is the last one rendered
            const inputs = getValueInputs(element);
            expect(isModified(inputs[inputs.length - 1])).toBe(true);
        });

        it('rejects an unnamed or duplicate field name', async () => {
            const element = buildStructural(SAMPLE);

            await openRootAddForm(element);
            clickConfirmAdd(element);
            await flush();
            expect(
                element.shadowRoot.querySelector('.add-error')
            ).not.toBeNull();
            expect(element.getJson()).toEqual(SAMPLE);

            setAddName(element, 'Last Name');
            clickConfirmAdd(element);
            await flush();
            expect(
                element.shadowRoot.querySelector('.add-error').textContent
            ).toContain('Last Name');
            expect(element.getJson()).toEqual(SAMPLE);
        });

        it('appends an item to a list without asking for a name', async () => {
            const element = buildStructural(SAMPLE);
            // The Tools branch is the only branch row
            const toolsRow = branchRowId(element, 'Tools');
            await openAddFormOn(element, toolsRow);
            // Arrays take positional labels, so no name field is offered
            expect(
                element.shadowRoot.querySelector('.add-form .add-name')
            ).toBeNull();
            clickConfirmAdd(element);
            await flush();

            expect(element.getJson().Tools).toEqual([
                'Hammer',
                'Handsaw',
                'Pliers',
                ''
            ]);
        });

        it('deletes a leaf field immediately', async () => {
            const element = buildStructural(SAMPLE);
            const handler = jest.fn();
            element.addEventListener('jsonchange', handler);

            clickDeleteFor(element, 'Middle Name');
            await flush();

            expect(handler).toHaveBeenCalledTimes(1);
            expect(element.getJson()['Middle Name']).toBeUndefined();
            expect(Object.keys(element.getJson())).toEqual([
                'First Name',
                'Last Name',
                'Age',
                'Born Date',
                'Tools'
            ]);
        });

        it('asks before deleting a group that has contents', async () => {
            const element = buildStructural(SAMPLE);

            clickDeleteFor(element, 'Tools');
            await flush();
            // Nothing gone yet — a confirmation is showing instead
            expect(element.getJson().Tools).toHaveLength(3);
            const confirm = element.shadowRoot.querySelector('.confirm-delete');
            expect(confirm.textContent).toContain('3 fields');

            element.shadowRoot
                .querySelector('.delete-confirm')
                .dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(element.getJson().Tools).toBeUndefined();
        });

        it('keeps the list when the delete confirmation is cancelled', async () => {
            const element = buildStructural(SAMPLE);
            clickDeleteFor(element, 'Tools');
            await flush();

            element.shadowRoot
                .querySelector('.delete-cancel')
                .dispatchEvent(new CustomEvent('click'));
            await flush();

            expect(
                element.shadowRoot.querySelector('.confirm-delete')
            ).toBeNull();
            expect(element.getJson()).toEqual(SAMPLE);
        });

        it('re-labels the remaining items after a list item is deleted', async () => {
            const element = buildStructural(SAMPLE);
            // Delete "Item 2" (Handsaw)
            clickDeleteFor(element, 'Item 2');
            await flush();

            expect(element.getJson().Tools).toEqual(['Hammer', 'Pliers']);
            expect(getFixedLabels(element)).toContain('Item 2');
            expect(getFixedLabels(element)).not.toContain('Item 3');
        });

        it('keeps the edit flags of surviving fields when a list item is deleted', async () => {
            const element = buildStructural(SAMPLE);
            // Edit the third tool, then delete the first one before it
            const toolInputs = getValueInputs(element);
            fireChange(toolInputs[7], 'Wrench'); // Pliers -> Wrench
            await flush();

            clickDeleteFor(element, 'Item 1');
            await flush();

            expect(element.getJson().Tools).toEqual(['Handsaw', 'Wrench']);
            // The edited item shifted from index 2 to index 1 but is still flagged
            const remaining = getValueInputs(element);
            expect(remaining[remaining.length - 1].value).toBe('Wrench');
            expect(isModified(remaining[remaining.length - 1])).toBe(true);
            expect(isModified(remaining[remaining.length - 2])).toBe(false);
        });
    });

    // -----------------------------------------------------------------
    // JF-13 - adding a child under a leaf
    // -----------------------------------------------------------------

    describe('adding children under a leaf', () => {
        it('offers an add button on every row, not only on branches', () => {
            const element = buildStructural(SAMPLE);
            // 5 top-level primitives + Tools + 3 items = 9 rows, all addable
            expect(queryAll(element, '.add-button')).toHaveLength(9);
        });

        it('turns a leaf into a group and nests the new field under it', async () => {
            const element = buildStructural(SAMPLE);
            const handler = jest.fn();
            element.addEventListener('jsonchange', handler);

            await addChildTo(element, 'Middle Name', { name: 'Suffix' });

            expect(handler).toHaveBeenCalledTimes(1);
            const result = element.getJson();
            expect(result['Middle Name']).toEqual({ Suffix: '' });
            // Converting is in-place: the key keeps its original position
            expect(Object.keys(result)).toEqual(Object.keys(SAMPLE));
        });

        it('can turn a leaf into a list instead, with no name needed', async () => {
            const element = buildStructural(SAMPLE);
            await openAddFormOn(element, rowIdFor(element, 'Middle Name'));
            setAddContainer(element, 'array');
            await flush();
            // A list item is positional, so the name box is withdrawn
            expect(
                element.shadowRoot.querySelector('.add-form .add-name')
            ).toBeNull();
            clickConfirmAdd(element);
            await flush();

            expect(element.getJson()['Middle Name']).toEqual(['']);
        });

        it('warns which value the conversion discards', async () => {
            const element = buildStructural(SAMPLE);
            await openAddFormOn(element, rowIdFor(element, 'Middle Name'));
            expect(
                element.shadowRoot.querySelector('.convert-warning').textContent
            ).toContain('"Arturo"');
        });

        it('shows no conversion controls when the target is already a branch', async () => {
            const element = buildStructural(SAMPLE);
            await openAddFormOn(element, rowIdFor(element, 'Tools'));
            expect(
                element.shadowRoot.querySelector('.convert-warning')
            ).toBeNull();
            expect(
                element.shadowRoot.querySelector('.add-form .add-container')
            ).toBeNull();
        });

        it('still requires a name when converting to a group', async () => {
            const element = buildStructural(SAMPLE);
            await openAddFormOn(element, rowIdFor(element, 'Middle Name'));
            clickConfirmAdd(element);
            await flush();

            expect(
                element.shadowRoot.querySelector('.add-error').textContent
            ).toBe('Give the field a name.');
            // Nothing was converted, so the JSON is untouched
            expect(element.getJson()).toEqual(SAMPLE);
        });

        it('keeps the converted field editable and nests deeper on demand', async () => {
            const element = buildStructural(SAMPLE);
            await addChildTo(element, 'Middle Name', {
                name: 'Detail',
                type: 'object'
            });
            // The grandchild goes under the group just created
            await addChildTo(element, 'Detail', { name: 'Note' });

            expect(element.getJson()['Middle Name']).toEqual({
                Detail: { Note: '' }
            });
        });

        it('preserves the type of a value typed into a converted field', async () => {
            const element = buildStructural(SAMPLE);
            await addChildTo(element, 'Age', { name: 'Years', type: 'number' });

            // The child renders in place under Age, not at the end
            fireChange(valueInputFor(element, 'Years'), '46');
            expect(element.getJson().Age).toEqual({ Years: 46 });
        });

        it('converts an array item too', async () => {
            const element = buildStructural(SAMPLE);
            await addChildTo(element, 'Item 2', { name: 'Brand' });

            expect(element.getJson().Tools).toEqual([
                'Hammer',
                { Brand: '' },
                'Pliers'
            ]);
        });

        it('drops the confidence envelope of the value it discards', async () => {
            const element = buildComponent(
                {
                    Name: { value: 'Carlos', confidence: 0.97 },
                    Age: { value: 45, confidence: 0.42 }
                },
                { editStructure: true, showConfidence: true }
            );
            await addChildTo(element, 'Name', { name: 'Given' });

            // Name is now a plain group; Age keeps its envelope untouched
            expect(element.getJson()).toEqual({
                Name: { Given: '' },
                Age: { value: 45, confidence: 0.42 }
            });
            expect(queryAll(element, '.confidence-badge')).toHaveLength(1);
        });

        it('deletes a converted field like any other branch', async () => {
            const element = buildStructural(SAMPLE);
            await addChildTo(element, 'Middle Name', { name: 'Suffix' });

            clickDeleteFor(element, 'Middle Name');
            await flush();
            // It has contents now, so it asks first
            expect(
                element.shadowRoot.querySelector('.confirm-delete')
            ).not.toBeNull();
            element.shadowRoot
                .querySelector('.delete-confirm')
                .dispatchEvent(new CustomEvent('click'));
            await flush();

            expect(element.getJson()['Middle Name']).toBeUndefined();
        });

        it('does nothing when editStructure is off', () => {
            const element = buildComponent(SAMPLE);
            expect(queryAll(element, '.add-button')).toHaveLength(0);
        });
    });

    // -----------------------------------------------------------------
    // collapsible
    // -----------------------------------------------------------------

    describe('collapsible', () => {
        it('is off by default, so no chevrons render', () => {
            const element = buildComponent(SAMPLE);
            expect(queryAll(element, '.collapse-toggle')).toHaveLength(0);
        });

        it('hides a group’s children when collapsed and shows them again', async () => {
            const element = buildComponent(SAMPLE, { collapsible: true });
            expect(getValueInputs(element)).toHaveLength(8);

            const toggle = element.shadowRoot.querySelector('.collapse-toggle');
            toggle.dispatchEvent(new CustomEvent('click'));
            await flush();
            // The three Tools items are gone; the five top-level ones remain
            expect(getValueInputs(element)).toHaveLength(5);
            expect(getFixedLabels(element)).toContain('Tools');

            element.shadowRoot
                .querySelector('.collapse-toggle')
                .dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(getValueInputs(element)).toHaveLength(8);
        });

        it('collapses and expands everything from the toolbar', async () => {
            const element = buildComponent(
                { A: { B: { C: 'deep' } }, D: 'top' },
                { collapsible: true }
            );
            expect(getValueInputs(element)).toHaveLength(2);

            clickButtonLabelled(element, 'Collapse all');
            await flush();
            expect(getValueInputs(element)).toHaveLength(1); // only D

            clickButtonLabelled(element, 'Expand all');
            await flush();
            expect(getValueInputs(element)).toHaveLength(2);
        });

        it('does not change the JSON', async () => {
            const element = buildComponent(SAMPLE, { collapsible: true });
            element.shadowRoot
                .querySelector('.collapse-toggle')
                .dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(element.getJson()).toEqual(SAMPLE);
        });
    });

    // -----------------------------------------------------------------
    // searchable
    // -----------------------------------------------------------------

    describe('searchable', () => {
        it('is off by default, so no search box renders', () => {
            const element = buildComponent(SAMPLE);
            expect(
                element.shadowRoot.querySelector('.search-input')
            ).toBeNull();
        });

        it('filters by field name and keeps the parent group for context', async () => {
            const element = buildComponent(SAMPLE, { searchable: true });
            await search(element, 'name');

            // First/Middle/Last Name match; nothing else does
            expect(getFixedLabels(element)).toEqual([
                'First Name',
                'Middle Name',
                'Last Name'
            ]);
        });

        it('filters by value', async () => {
            const element = buildComponent(SAMPLE, { searchable: true });
            await search(element, 'handsaw');
            // The matching item plus its Tools parent, for context
            expect(getFixedLabels(element)).toEqual(['Tools', 'Item 2']);
        });

        it('shows a whole group when the group name matches', async () => {
            const element = buildComponent(SAMPLE, { searchable: true });
            await search(element, 'tools');
            expect(getFixedLabels(element)).toEqual([
                'Tools',
                'Item 1',
                'Item 2',
                'Item 3'
            ]);
        });

        it('reveals matches inside a collapsed group', async () => {
            const element = buildComponent(SAMPLE, {
                searchable: true,
                collapsible: true
            });
            element.shadowRoot
                .querySelector('.collapse-toggle')
                .dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(getFixedLabels(element)).not.toContain('Item 2');

            await search(element, 'handsaw');
            expect(getFixedLabels(element)).toContain('Item 2');
        });

        it('reports when nothing matches, without touching the JSON', async () => {
            const element = buildComponent(SAMPLE, { searchable: true });
            await search(element, 'zzzz');
            expect(getValueInputs(element)).toHaveLength(0);
            expect(
                element.shadowRoot.querySelector('.empty-state').textContent
            ).toContain('No fields match');
            expect(element.getJson()).toEqual(SAMPLE);
        });

        it('restores every row when the search is cleared', async () => {
            const element = buildComponent(SAMPLE, { searchable: true });
            await search(element, 'name');
            await search(element, '');
            expect(getValueInputs(element)).toHaveLength(8);
        });
    });

    // -----------------------------------------------------------------
    // showConfidence
    // -----------------------------------------------------------------

    describe('showConfidence', () => {
        const ENVELOPED = {
            Name: { value: 'Carlos', confidence: 0.97 },
            Age: { value: 45, confidence: 0.42 }
        };

        it('leaves envelopes as ordinary JSON when off', () => {
            const element = buildComponent(ENVELOPED);
            // Two groups of {value, confidence} => four value textboxes
            expect(getValueInputs(element)).toHaveLength(4);
            expect(queryAll(element, '.confidence-badge')).toHaveLength(0);
        });

        it('unwraps envelopes and badges the confidence when on', () => {
            const element = buildComponent(ENVELOPED, { showConfidence: true });
            const inputs = getValueInputs(element);
            expect(inputs).toHaveLength(2);
            expect(inputs[0].value).toBe('Carlos');
            expect(inputs[1].value).toBe('45');

            const badges = queryAll(element, '.confidence-badge').map(
                (b) => b.textContent
            );
            expect(badges).toEqual(['97%', '42%']);
        });

        it('marks confidence below the threshold as low', () => {
            const element = buildComponent(ENVELOPED, { showConfidence: true });
            const badges = queryAll(element, '.confidence-badge');
            expect(badges[0].classList.contains('confidence-badge_low')).toBe(
                false
            );
            expect(badges[1].classList.contains('confidence-badge_low')).toBe(
                true
            );
        });

        it('honours a custom threshold, as a fraction or a percentage', () => {
            const asFraction = buildComponent(ENVELOPED, {
                showConfidence: true,
                confidenceThreshold: 0.99
            });
            expect(
                queryAll(asFraction, '.confidence-badge').filter((b) =>
                    b.classList.contains('confidence-badge_low')
                )
            ).toHaveLength(2);

            const asPercent = buildComponent(ENVELOPED, {
                showConfidence: true,
                confidenceThreshold: '30'
            });
            expect(
                queryAll(asPercent, '.confidence-badge').filter((b) =>
                    b.classList.contains('confidence-badge_low')
                )
            ).toHaveLength(0);
        });

        it('restores the envelope in the output JSON, edits included', () => {
            const element = buildComponent(ENVELOPED, { showConfidence: true });
            fireChange(getValueInputs(element)[0], 'Carla');

            expect(element.getJson()).toEqual({
                Name: { value: 'Carla', confidence: 0.97 },
                Age: { value: 45, confidence: 0.42 }
            });
        });

        it('keeps the type of an enveloped value', () => {
            const element = buildComponent(ENVELOPED, { showConfidence: true });
            fireChange(getValueInputs(element)[1], '46');
            expect(element.getJson().Age.value).toBe(46);
        });

        it('does not treat a business field named "value" as an envelope', () => {
            const element = buildComponent(
                { Item: { value: 'x', unit: 'kg' } },
                { showConfidence: true }
            );
            // Three keys / wrong shape, so it stays an ordinary group
            expect(getValueInputs(element)).toHaveLength(2);
            expect(queryAll(element, '.confidence-badge')).toHaveLength(0);
        });
    });

    // -----------------------------------------------------------------
    // validateTypes
    // -----------------------------------------------------------------

    describe('validateTypes', () => {
        function isInvalid(input) {
            return input.classList.contains('field-invalid');
        }

        it('is off by default, so a bad number is kept silently as a string', () => {
            const element = buildComponent(SAMPLE);
            fireChange(getValueInputs(element)[3], 'forty-six');
            expect(element.isValid).toBe(true);
            expect(element.getJson().Age).toBe('forty-six');
        });

        it('flags a number field that no longer holds a number', async () => {
            const element = buildComponent(SAMPLE, { validateTypes: true });
            const ageInput = getValueInputs(element)[3];

            fireChange(ageInput, 'forty-six');
            await flush();
            expect(isInvalid(ageInput)).toBe(true);
            expect(element.isValid).toBe(false);
            expect(
                element.shadowRoot.querySelector('.field-error').textContent
            ).toBe('Enter a number.');

            fireChange(ageInput, '46');
            await flush();
            expect(isInvalid(getValueInputs(element)[3])).toBe(false);
            expect(element.isValid).toBe(true);
        });

        it('flags a boolean field that no longer holds true or false', async () => {
            const element = buildComponent(
                { Active: true },
                { validateTypes: true }
            );
            const input = getValueInputs(element)[0];

            fireChange(input, 'yes');
            await flush();
            expect(isInvalid(input)).toBe(true);
            expect(
                element.shadowRoot.querySelector('.field-error').textContent
            ).toBe('Enter true or false.');

            fireChange(input, 'false');
            await flush();
            expect(element.isValid).toBe(true);
            expect(element.getJson().Active).toBe(false);
        });

        it('accepts any text in text fields and in fields that loaded empty', async () => {
            const element = buildComponent(
                { Note: 'hello', Missing: null },
                { validateTypes: true }
            );
            const inputs = getValueInputs(element);
            fireChange(inputs[0], '12345');
            fireChange(inputs[1], 'now filled in');
            await flush();
            expect(element.isValid).toBe(true);
        });

        it('reports validity on the jsonchange event', () => {
            const element = buildComponent(SAMPLE, { validateTypes: true });
            const handler = jest.fn();
            element.addEventListener('jsonchange', handler);

            fireChange(getValueInputs(element)[3], 'forty-six');
            expect(handler.mock.calls[0][0].detail.valid).toBe(false);

            fireChange(getValueInputs(element)[3], '46');
            expect(handler.mock.calls[1][0].detail.valid).toBe(true);
        });

        it('shows the invalid cue instead of the edited cue', async () => {
            const element = buildComponent(SAMPLE, { validateTypes: true });
            const ageInput = getValueInputs(element)[3];
            fireChange(ageInput, 'forty-six');
            await flush();
            expect(isInvalid(ageInput)).toBe(true);
            expect(isModified(ageInput)).toBe(false);
        });

        it('validates fields already on screen when switched on late', async () => {
            const element = buildComponent(SAMPLE);
            fireChange(getValueInputs(element)[3], 'forty-six');
            await flush();
            expect(element.isValid).toBe(true);

            element.validateTypes = true;
            await flush();
            expect(element.isValid).toBe(false);
            expect(isInvalid(getValueInputs(element)[3])).toBe(true);
        });
    });

    // -----------------------------------------------------------------
    // Features are independent
    // -----------------------------------------------------------------

    it('accepts every flag as the string Flow and App Builder pass', () => {
        const element = buildComponent(SAMPLE, {
            editStructure: 'true',
            collapsible: 'true',
            searchable: 'true',
            showConfidence: 'true',
            validateTypes: 'true'
        });
        expect(element.editStructure).toBe(true);
        expect(element.collapsible).toBe(true);
        expect(element.searchable).toBe(true);
        expect(element.showConfidence).toBe(true);
        expect(element.validateTypes).toBe(true);
    });

    it('renders no toolbar at all when every feature is off', () => {
        const element = buildComponent(SAMPLE);
        expect(
            element.shadowRoot.querySelector('.json-form-toolbar')
        ).toBeNull();
    });
});
