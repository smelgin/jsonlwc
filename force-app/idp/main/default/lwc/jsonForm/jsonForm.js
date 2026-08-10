import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

const LABEL_INPUT_CLASS = 'label-input';
const VALUE_INPUT_CLASS = 'value-input';
const MODIFIED_CLASS = 'field-modified';

/**
 * Renders arbitrary JSON as a hierarchical form. Every object key gets an
 * editable "label" textbox and every primitive value gets an editable
 * "value" textbox. Array items get a fixed positional label. Any edit
 * dispatches a `jsonchange` event carrying the modified JSON.
 *
 * Textboxes holding something other than what was originally loaded are
 * outlined in green; restoring the original text clears the outline again.
 */
export default class JsonForm extends LightningElement {
    rows = [];

    _data;
    _rowsById = new Map();
    _idCounter = 0;
    _jsonInput;
    _editLabels = false;

    /**
     * Whether object keys may be renamed. Off by default: most hosts want the
     * user to correct values against a fixed schema, so the labels render as
     * plain text unless the developer opts in. Array items are never
     * renameable either way — their positional labels are not part of the JSON.
     */
    @api
    get editLabels() {
        return this._editLabels;
    }
    set editLabels(value) {
        // Flow and App Builder can hand a boolean over as the string "true"
        const enabled = value === true || value === 'true';
        if (enabled === this._editLabels) {
            return;
        }
        this._editLabels = enabled;
        this.applyLabelEditability();
    }

    /** JSON to edit. Accepts an object/array or a JSON string. */
    @api
    get jsonData() {
        return this._data;
    }
    set jsonData(value) {
        this.applyJson(value);
    }

    /**
     * String-typed variant of jsonData for App Builder and Flow screens,
     * where admins configure the source JSON as text.
     */
    @api
    get jsonInput() {
        return this._jsonInput;
    }
    set jsonInput(value) {
        this._jsonInput = value;
        this.applyJson(value);
    }

    /** The modified JSON as a string. Exposed as a Flow output attribute. */
    @api
    get jsonOutput() {
        return this._data === undefined ? '' : JSON.stringify(this._data);
    }

    /** Returns the current (possibly modified) JSON as an object. */
    @api
    getJson() {
        return this._data === undefined
            ? undefined
            : JSON.parse(JSON.stringify(this._data));
    }

    /** Returns the current (possibly modified) JSON as a formatted string. */
    @api
    getJsonString(indent = 3) {
        return JSON.stringify(this._data, null, indent);
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    applyJson(value) {
        let parsed = value;
        if (typeof value === 'string') {
            try {
                parsed = JSON.parse(value);
            } catch {
                parsed = undefined;
            }
        }
        // Deep-clone so edits never mutate the object owned by the parent
        this._data =
            parsed !== undefined && parsed !== null
                ? JSON.parse(JSON.stringify(parsed))
                : undefined;
        this.rebuildRows();
    }

    // ---------------------------------------------------------------------
    // Row building
    // ---------------------------------------------------------------------

    rebuildRows() {
        const rows = [];
        this._rowsById = new Map();
        this._idCounter = 0;
        if (this._data !== null && typeof this._data === 'object') {
            this.flatten(this._data, [], 0, rows);
        }
        this.rows = rows;
    }

    flatten(node, path, level, rows) {
        const isArrayNode = Array.isArray(node);
        const keys = isArrayNode
            ? node.map((item, index) => index)
            : Object.keys(node);

        keys.forEach((key) => {
            const value = node[key];
            const rowPath = [...path, key];
            const keyEditable = !isArrayNode;
            const label = isArrayNode ? `Item ${key + 1}` : key;

            if (value !== null && typeof value === 'object') {
                const badge = Array.isArray(value)
                    ? `List · ${value.length} item${value.length === 1 ? '' : 's'}`
                    : 'Group';
                rows.push(
                    this.makeRow({
                        label,
                        keyEditable,
                        level,
                        rowPath,
                        isBranch: true,
                        badge
                    })
                );
                this.flatten(value, rowPath, level + 1, rows);
            } else {
                const valueType = value === null ? 'null' : typeof value;
                rows.push(
                    this.makeRow({
                        label,
                        keyEditable,
                        level,
                        rowPath,
                        isBranch: false,
                        value: value === null ? '' : String(value),
                        valueType
                    })
                );
            }
        });
    }

    makeRow(props) {
        const id = String(this._idCounter++);
        const row = {
            id,
            indentStyle: `padding-left: ${props.level * 1.75}rem;`,
            hasFixedLabel: !props.keyEditable || !this._editLabels,
            // Pristine baseline the green outline is measured against.
            // `props.value` is never rewritten once the row is built, so it
            // doubles as the baseline for the value textbox.
            originalLabel: props.label,
            labelClass: LABEL_INPUT_CLASS,
            valueClass: VALUE_INPUT_CLASS,
            ...props
        };
        this._rowsById.set(id, row);
        return row;
    }

    /**
     * Swaps the label textboxes for plain text (or back) in place. Patching
     * the existing rows rather than rebuilding them keeps the JSON, and the
     * green outlines tracking it, intact when a host flips the flag late.
     */
    applyLabelEditability() {
        if (this.rows.length === 0) {
            return;
        }
        this._rowsById.forEach((row) => {
            row.hasFixedLabel = !row.keyEditable || !this._editLabels;
        });
        this.rows = [...this.rows];
    }

    // ---------------------------------------------------------------------
    // Edit handling
    // ---------------------------------------------------------------------

    handleValueChange(event) {
        const row = this._rowsById.get(event.target.dataset.id);
        if (!row) {
            return;
        }
        const parent = this.getNode(row.rowPath.slice(0, -1));
        const key = row.rowPath[row.rowPath.length - 1];
        const text = event.target.value;
        parent[key] = this.coerce(text, row.valueType);
        this.setModified(
            row,
            'valueClass',
            VALUE_INPUT_CLASS,
            text !== row.value
        );
        this.notifyChange();
    }

    handleLabelChange(event) {
        const row = this._rowsById.get(event.target.dataset.id);
        if (!row) {
            return;
        }
        if (this.applyRename(row, event.target.value)) {
            // Only a rename that reached the JSON counts, so a rejected one
            // (empty or duplicate key) leaves the outline as it was.
            this.setModified(
                row,
                'labelClass',
                LABEL_INPUT_CLASS,
                row.label !== row.originalLabel
            );
            this.notifyChange();
        }
    }

    /**
     * Adds or removes the green-outline class on one of a row's textboxes.
     * Rows are plain objects, so `rows` has to be reassigned for the template
     * to pick the change up — done only when the flag actually flips, to keep
     * ordinary keystrokes from re-rendering the whole form.
     */
    setModified(row, classProperty, baseClass, isModified) {
        const next = isModified ? `${baseClass} ${MODIFIED_CLASS}` : baseClass;
        if (row[classProperty] === next) {
            return;
        }
        row[classProperty] = next;
        this.rows = [...this.rows];
    }

    // If a rename could not be applied (empty or duplicate key), snap the
    // textbox back to the key actually stored in the JSON when leaving it.
    handleLabelBlur(event) {
        const row = this._rowsById.get(event.target.dataset.id);
        if (row && event.target.value !== row.label) {
            event.target.value = row.label;
        }
    }

    /**
     * Renames an object key in place, preserving key order, and updates the
     * stored paths of every descendant row. Returns false when the new key
     * is empty or already exists on the same object.
     */
    applyRename(row, newKey) {
        const oldKey = row.rowPath[row.rowPath.length - 1];
        if (newKey === oldKey) {
            return false;
        }
        const parentPath = row.rowPath.slice(0, -1);
        const parent = this.getNode(parentPath);
        if (
            !newKey ||
            Object.prototype.hasOwnProperty.call(parent, newKey)
        ) {
            return false;
        }

        const renamed = {};
        Object.keys(parent).forEach((k) => {
            renamed[k === oldKey ? newKey : k] = parent[k];
        });
        this.setNode(parentPath, renamed);

        const depth = parentPath.length;
        this._rowsById.forEach((r) => {
            if (
                r.rowPath.length > depth &&
                r.rowPath[depth] === oldKey &&
                parentPath.every((seg, i) => r.rowPath[i] === seg)
            ) {
                r.rowPath[depth] = newKey;
            }
        });
        row.label = newKey;
        return true;
    }

    /**
     * Converts the textbox string back to the value's original JSON type so
     * numbers stay numbers and booleans stay booleans. Falls back to the raw
     * string when the text no longer parses as that type.
     */
    coerce(raw, valueType) {
        if (valueType === 'number') {
            const n = Number(raw);
            return raw.trim() !== '' && !Number.isNaN(n) ? n : raw;
        }
        if (valueType === 'boolean') {
            const lowered = raw.trim().toLowerCase();
            if (lowered === 'true') {
                return true;
            }
            if (lowered === 'false') {
                return false;
            }
            return raw;
        }
        if (valueType === 'null') {
            return raw === '' ? null : raw;
        }
        return raw;
    }

    getNode(path) {
        return path.reduce((node, key) => node[key], this._data);
    }

    setNode(path, newValue) {
        if (path.length === 0) {
            this._data = newValue;
            return;
        }
        const parent = this.getNode(path.slice(0, -1));
        parent[path[path.length - 1]] = newValue;
    }

    notifyChange() {
        this.dispatchEvent(
            new CustomEvent('jsonchange', {
                detail: {
                    value: this.getJson(),
                    jsonString: this.getJsonString()
                }
            })
        );
        // Keep the jsonOutput Flow attribute in sync (no-op outside Flow)
        this.dispatchEvent(
            new FlowAttributeChangeEvent('jsonOutput', this.jsonOutput)
        );
    }
}
