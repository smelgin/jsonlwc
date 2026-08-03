import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

/**
 * Renders arbitrary JSON as a hierarchical form. Every object key gets an
 * editable "label" textbox and every primitive value gets an editable
 * "value" textbox. Array items get a fixed positional label. Any edit
 * dispatches a `jsonchange` event carrying the modified JSON.
 */
export default class JsonForm extends LightningElement {
    rows = [];

    _data;
    _rowsById = new Map();
    _idCounter = 0;
    _jsonInput;

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
            hasFixedLabel: !props.keyEditable,
            ...props
        };
        this._rowsById.set(id, row);
        return row;
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
        parent[key] = this.coerce(event.target.value, row.valueType);
        this.notifyChange();
    }

    handleLabelChange(event) {
        const row = this._rowsById.get(event.target.dataset.id);
        if (!row) {
            return;
        }
        if (this.applyRename(row, event.target.value)) {
            this.notifyChange();
        }
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
