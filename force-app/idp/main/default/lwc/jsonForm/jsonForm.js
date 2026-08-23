import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

const LABEL_INPUT_CLASS = 'label-input';
const VALUE_INPUT_CLASS = 'value-input';
const MODIFIED_CLASS = 'field-modified';
const INVALID_CLASS = 'field-invalid';

const KIND_OBJECT = 'object';
const KIND_ARRAY = 'array';
const KIND_LEAF = 'leaf';

const TYPE_TEXT = 'string';
const TYPE_NUMBER = 'number';
const TYPE_BOOLEAN = 'boolean';
const TYPE_NULL = 'null';

/** Choices offered when adding a field. Mirrors what JSON can hold. */
const TYPE_OPTIONS = [
    { label: 'Text', value: TYPE_TEXT },
    { label: 'Number', value: TYPE_NUMBER },
    { label: 'True / false', value: TYPE_BOOLEAN },
    { label: 'Empty', value: TYPE_NULL },
    { label: 'Group', value: KIND_OBJECT },
    { label: 'List', value: KIND_ARRAY }
];

/** What a leaf becomes when a child is added under it (JF-13). */
const CONTAINER_OPTIONS = [
    { label: 'Group', value: KIND_OBJECT },
    { label: 'List', value: KIND_ARRAY }
];

const DEFAULT_CONFIDENCE_THRESHOLD = 0.8;

/** Flow and App Builder hand booleans over as the strings "true"/"false". */
function toBoolean(value) {
    return value === true || value === 'true';
}

/**
 * Renders arbitrary JSON as a hierarchical form. Every object key gets an
 * editable "label" textbox and every primitive value gets an editable
 * "value" textbox. Array items get a fixed positional label. Any edit
 * dispatches a `jsonchange` event carrying the modified JSON.
 *
 * Textboxes holding something other than what was originally loaded are
 * outlined in green; restoring the original text clears the outline again.
 *
 * Internally the form owns a tree of nodes — one per JSON member, each with
 * a stable id — and the JSON is *derived* from that tree on demand. Holding
 * the tree rather than re-deriving rows from the JSON is what lets a field's
 * "edited" baseline survive a rename, an insertion, or a deletion that
 * shifts every array index after it.
 *
 * Everything beyond editing existing values is opt-in, so a host that wants
 * the original behaviour gets it by leaving the flags alone:
 *  - editLabels     rename object keys
 *  - editStructure  add and delete fields, array items and groups
 *  - collapsible    collapse and expand groups and lists
 *  - searchable     filter the form by field name or value
 *  - showConfidence unwrap {value, confidence} envelopes and badge them
 *  - validateTypes  flag values that no longer parse as their loaded type
 */
export default class JsonForm extends LightningElement {
    rows = [];
    typeOptions = TYPE_OPTIONS;
    containerOptions = CONTAINER_OPTIONS;

    _root;
    _scalar;
    _rowsById = new Map();
    _nodesById = new Map();
    _idCounter = 0;
    _jsonInput;

    _editLabels = false;
    _editStructure = false;
    _collapsible = false;
    _searchable = false;
    _showConfidence = false;
    _validateTypes = false;
    _confidenceThreshold = DEFAULT_CONFIDENCE_THRESHOLD;

    _searchTerm = '';
    _addTargetId;
    _addName = '';
    _addType = TYPE_TEXT;
    _addContainerKind = KIND_OBJECT;
    _addError;
    _confirmDeleteId;

    // ---------------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------------

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
        this._editLabels = toBoolean(value);
        this.rebuildRows();
    }

    /** Whether fields, array items and groups may be added and deleted. */
    @api
    get editStructure() {
        return this._editStructure;
    }
    set editStructure(value) {
        this._editStructure = toBoolean(value);
        this._addTargetId = undefined;
        this._confirmDeleteId = undefined;
        this.rebuildRows();
    }

    /** Whether groups and lists can be collapsed and expanded. */
    @api
    get collapsible() {
        return this._collapsible;
    }
    set collapsible(value) {
        this._collapsible = toBoolean(value);
        this.rebuildRows();
    }

    /** Whether a search box filters the form by field name or value. */
    @api
    get searchable() {
        return this._searchable;
    }
    set searchable(value) {
        this._searchable = toBoolean(value);
        if (!this._searchable) {
            this._searchTerm = '';
        }
        this.rebuildRows();
    }

    /**
     * Whether `{"value": …, "confidence": 0.93}` envelopes are unwrapped and
     * shown as a confidence badge on the field. Off by default, because with
     * it off an envelope is ordinary JSON and renders as a group of two
     * fields — which is what a host that knows nothing about confidence
     * should see. The envelope is restored on output either way.
     *
     * Toggling this after load rebuilds the tree from the current JSON: the
     * user's edits survive, but the "edited" baselines are taken afresh.
     */
    @api
    get showConfidence() {
        return this._showConfidence;
    }
    set showConfidence(value) {
        const enabled = toBoolean(value);
        if (enabled === this._showConfidence) {
            return;
        }
        this._showConfidence = enabled;
        if (this._root) {
            this.applyJson(this.getJson());
        }
    }

    /**
     * Confidence at or above which a field counts as reliable. Anything below
     * is badged in red. Accepts a fraction (0.8) or a percentage (80).
     */
    @api
    get confidenceThreshold() {
        return this._confidenceThreshold;
    }
    set confidenceThreshold(value) {
        const parsed = Number(value);
        if (!Number.isNaN(parsed) && parsed > 0) {
            this._confidenceThreshold = parsed > 1 ? parsed / 100 : parsed;
            this.rebuildRows();
        }
    }

    /**
     * Whether edits are checked against the type the field arrived with, so
     * text where a number belongs is flagged rather than silently kept as a
     * string. Only numbers and booleans can fail: a field that loaded as text
     * accepts any text, and one that loaded empty accepts anything.
     */
    @api
    get validateTypes() {
        return this._validateTypes;
    }
    set validateTypes(value) {
        this._validateTypes = toBoolean(value);
        this.revalidate();
        this.rebuildRows();
    }

    /** JSON to edit. Accepts an object/array or a JSON string. */
    @api
    get jsonData() {
        return this.getJson();
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
        const data = this.getJson();
        return data === undefined ? '' : JSON.stringify(data);
    }

    /** Returns the current (possibly modified) JSON as an object. */
    @api
    getJson() {
        return this._root ? this.serialize(this._root) : this._scalar;
    }

    /** Returns the current (possibly modified) JSON as a formatted string. */
    @api
    getJsonString(indent = 3) {
        return JSON.stringify(this.getJson(), null, indent);
    }

    /** False when validateTypes is on and some field no longer parses as its
     *  loaded type. Always true when validation is off. */
    @api
    get isValid() {
        return this.invalidNodes().length === 0;
    }

    // ---------------------------------------------------------------------
    // Loading
    // ---------------------------------------------------------------------

    applyJson(value) {
        let parsed = value;
        if (typeof value === 'string') {
            try {
                parsed = JSON.parse(value);
            } catch {
                parsed = undefined;
            }
        }
        this._searchTerm = '';
        this._addTargetId = undefined;
        this._confirmDeleteId = undefined;
        this._idCounter = 0;
        this._root = undefined;
        this._scalar = undefined;
        this._nodesById = new Map();

        if (parsed !== undefined && parsed !== null) {
            if (typeof parsed === 'object') {
                this._root = this.buildNode(parsed, null, false, null);
            } else {
                this._scalar = parsed;
            }
        }
        this.rebuildRows();
    }

    /**
     * Builds one node and its descendants. `key` is the object key the node
     * sits under, or its index when the parent is an array — array items have
     * no name of their own, so their baseline key stays null.
     */
    buildNode(raw, key, isArrayItem, parent) {
        const node = {
            id: String(this._idCounter++),
            key,
            baselineKey: isArrayItem ? null : key,
            isArrayItem,
            isNew: false,
            parent,
            collapsed: false,
            envelope: undefined,
            error: undefined
        };
        this._nodesById.set(node.id, node);

        // Envelopes can nest; the innermost confidence is the one that counts,
        // matching IdpJsonReader.
        let content = raw;
        while (this._showConfidence && this.isEnvelope(content)) {
            node.envelope = { confidence: content.confidence };
            content = content.value;
        }

        if (content !== null && typeof content === 'object') {
            const isArray = Array.isArray(content);
            node.kind = isArray ? KIND_ARRAY : KIND_OBJECT;
            node.children = isArray
                ? content.map((item, index) =>
                      this.buildNode(item, index, true, node)
                  )
                : Object.keys(content).map((childKey) =>
                      this.buildNode(content[childKey], childKey, false, node)
                  );
        } else {
            node.kind = KIND_LEAF;
            node.value = content;
            node.valueType = content === null ? TYPE_NULL : typeof content;
            node.text = content === null ? '' : String(content);
            node.baselineText = node.text;
        }
        return node;
    }

    /**
     * Only the exact two-key {value, confidence} shape is an envelope, so a
     * legitimate business field named "value" can never be swallowed. Kept
     * deliberately identical to IdpJsonReader.isEnvelope.
     */
    isEnvelope(node) {
        if (node === null || typeof node !== 'object' || Array.isArray(node)) {
            return false;
        }
        const keys = Object.keys(node);
        return (
            keys.length === 2 &&
            keys.includes('value') &&
            keys.includes('confidence') &&
            (node.confidence === null || typeof node.confidence === 'number')
        );
    }

    /** Rebuilds the JSON from the tree, restoring any envelope it came in. */
    serialize(node) {
        let out;
        if (node.kind === KIND_OBJECT) {
            out = {};
            node.children.forEach((child) => {
                out[child.key] = this.serialize(child);
            });
        } else if (node.kind === KIND_ARRAY) {
            out = node.children.map((child) => this.serialize(child));
        } else {
            out = node.value;
        }
        if (node.envelope) {
            out = { value: out, confidence: node.envelope.confidence };
        }
        return out;
    }

    // ---------------------------------------------------------------------
    // Row building
    // ---------------------------------------------------------------------

    rebuildRows() {
        const rows = [];
        this._rowsById = new Map();
        if (this._root && this._root.children) {
            const matches = this._searchTerm
                ? this.computeMatches()
                : undefined;
            this.collectRows(this._root, 0, rows, matches, false);
        }
        this.rows = rows;
    }

    collectRows(node, level, rows, matches, ancestorMatched) {
        node.children.forEach((child, index) => {
            const selfMatch = matches ? matches.self.has(child.id) : false;
            const visible =
                !matches ||
                selfMatch ||
                ancestorMatched ||
                matches.descendant.has(child.id);
            if (!visible) {
                return;
            }
            rows.push(this.makeRow(child, index, level));
            if (child.kind !== KIND_LEAF) {
                // A search overrides collapse, so a match can never hide
                // inside a group the user happened to have closed.
                const hidden = child.collapsed && !matches;
                if (!hidden) {
                    this.collectRows(
                        child,
                        level + 1,
                        rows,
                        matches,
                        ancestorMatched || selfMatch
                    );
                }
            }
        });
    }

    /** Ids of the nodes matching the search term, and of those with a
     *  matching descendant (kept so a match is shown in context). */
    computeMatches() {
        const term = this._searchTerm.toLowerCase();
        const self = new Set();
        const descendant = new Set();

        const walk = (node, index) => {
            let hit = this.labelOf(node, index).toLowerCase().includes(term);
            if (
                !hit &&
                node.kind === KIND_LEAF &&
                node.text.toLowerCase().includes(term)
            ) {
                hit = true;
            }
            let childHit = false;
            if (node.children) {
                node.children.forEach((child, childIndex) => {
                    if (walk(child, childIndex)) {
                        childHit = true;
                    }
                });
            }
            if (hit) {
                self.add(node.id);
            }
            if (childHit) {
                descendant.add(node.id);
            }
            return hit || childHit;
        };

        this._root.children.forEach((child, index) => walk(child, index));
        return { self, descendant };
    }

    labelOf(node, index) {
        return node.isArrayItem ? `Item ${index + 1}` : String(node.key);
    }

    makeRow(node, index, level) {
        const isBranch = node.kind !== KIND_LEAF;
        // JF-13: a leaf can take a child too, by becoming a container first.
        const converting = !isBranch;
        const containerKind = converting ? this._addContainerKind : node.kind;
        const row = {
            id: node.id,
            label: this.labelOf(node, index),
            indentStyle: `padding-left: ${level * 1.75}rem;`,
            hasFixedLabel: node.isArrayItem || !this._editLabels,
            isBranch,
            badge: isBranch ? this.badgeFor(node) : undefined,
            value: isBranch ? undefined : node.text,
            // Collapse
            showToggle: this._collapsible && isBranch,
            toggleIcon: node.collapsed
                ? 'utility:chevronright'
                : 'utility:chevrondown',
            toggleTitle: node.collapsed ? 'Expand' : 'Collapse',
            // Structure
            showDelete: this._editStructure,
            showAdd: this._editStructure,
            addTitle: this.addTitleFor(node),
            isConfirmingDelete: this._confirmDeleteId === node.id,
            confirmMessage: this.confirmMessageFor(node),
            isAdding: this._addTargetId === node.id,
            addIsConversion: converting,
            addConversionMessage: converting
                ? this.conversionMessageFor(node)
                : undefined,
            addContainerKind: this._addContainerKind,
            addNeedsName: containerKind === KIND_OBJECT,
            addName: this._addName,
            addType: this._addType,
            addError: this._addError
        };
        this.decorate(row, node);
        this._rowsById.set(node.id, row);
        return row;
    }

    addTitleFor(node) {
        if (node.kind === KIND_ARRAY) {
            return 'Add item';
        }
        return node.kind === KIND_OBJECT ? 'Add field' : 'Add child field';
    }

    /** Warning shown before a leaf is turned into a container. The value it
     *  holds is named outright, because adding the child discards it. */
    conversionMessageFor(node) {
        const held =
            node.text === '' || node.text === undefined
                ? 'its empty value'
                : `"${node.text}"`;
        return `This field holds a value. Adding a child turns it into a container and discards ${held}.`;
    }

    badgeFor(node) {
        if (node.kind === KIND_ARRAY) {
            const count = node.children.length;
            return `List · ${count} item${count === 1 ? '' : 's'}`;
        }
        return 'Group';
    }

    confirmMessageFor(node) {
        if (node.kind === KIND_LEAF || !node.children.length) {
            return undefined;
        }
        const count = node.children.length;
        return `Delete this ${
            node.kind === KIND_ARRAY ? 'list' : 'group'
        } and its ${count} field${count === 1 ? '' : 's'}?`;
    }

    /**
     * Writes the state-dependent parts of a row: the green "edited" outline,
     * the red invalid outline and message, and the confidence badge. Split
     * out of makeRow so an ordinary keystroke can refresh one row in place
     * instead of rebuilding the whole form.
     */
    decorate(row, node) {
        const labelEdited =
            node.isNew ||
            node.converted ||
            (node.baselineKey !== null &&
                node.baselineKey !== undefined &&
                node.key !== node.baselineKey);
        row.labelClass = labelEdited
            ? `${LABEL_INPUT_CLASS} ${MODIFIED_CLASS}`
            : LABEL_INPUT_CLASS;

        if (node.kind === KIND_LEAF) {
            const valueEdited =
                node.isNew ||
                (node.baselineText !== null &&
                    node.baselineText !== undefined &&
                    node.text !== node.baselineText);
            // An invalid field is shown as invalid rather than as edited —
            // it is always both, and the error is the more useful cue.
            if (node.error) {
                row.valueClass = `${VALUE_INPUT_CLASS} ${INVALID_CLASS}`;
            } else if (valueEdited) {
                row.valueClass = `${VALUE_INPUT_CLASS} ${MODIFIED_CLASS}`;
            } else {
                row.valueClass = VALUE_INPUT_CLASS;
            }
            row.hasError = !!node.error;
            row.errorMessage = node.error;
        }

        const confidence = node.envelope ? node.envelope.confidence : undefined;
        row.hasConfidence =
            this._showConfidence &&
            confidence !== undefined &&
            confidence !== null;
        if (row.hasConfidence) {
            // Accept both 0.93 and 93 — IDP services report either.
            const fraction = confidence > 1 ? confidence / 100 : confidence;
            row.confidenceLabel = `${Math.round(fraction * 100)}%`;
            row.confidenceClass =
                fraction < this._confidenceThreshold
                    ? 'confidence-badge confidence-badge_low'
                    : 'confidence-badge';
        }
    }

    /** Re-decorates one row in place, reassigning `rows` only when something
     *  visible actually changed, so typing does not re-render the form. */
    refreshRow(node) {
        const row = this._rowsById.get(node.id);
        if (!row) {
            return;
        }
        const before = `${row.labelClass}|${row.valueClass}|${row.errorMessage}`;
        this.decorate(row, node);
        const after = `${row.labelClass}|${row.valueClass}|${row.errorMessage}`;
        if (before !== after) {
            this.rows = [...this.rows];
        }
    }

    // ---------------------------------------------------------------------
    // Template state
    // ---------------------------------------------------------------------

    get hasRows() {
        return this.rows.length > 0;
    }

    get hasToolbar() {
        return this._searchable || this._collapsible || this.canAddToRoot;
    }

    get canAddToRoot() {
        return this._editStructure && !!this._root;
    }

    get isAddingToRoot() {
        return !!this._root && this._addTargetId === this._root.id;
    }

    get rootNeedsName() {
        return !!this._root && this._root.kind === KIND_OBJECT;
    }

    get addName() {
        return this._addName;
    }

    get addType() {
        return this._addType;
    }

    get addError() {
        return this._addError;
    }

    get searchTerm() {
        return this._searchTerm;
    }

    get noMatches() {
        return !this.hasRows && !!this._searchTerm;
    }

    get isEmpty() {
        return !this.hasRows && !this._searchTerm;
    }

    // ---------------------------------------------------------------------
    // Value and label editing
    // ---------------------------------------------------------------------

    handleValueChange(event) {
        const node = this.nodeFor(event.target.dataset.id);
        if (!node) {
            return;
        }
        const text = event.target.value;
        node.text = text;
        node.value = this.coerce(text, node.valueType);
        node.error = this.errorFor(node, text);
        this.refreshRow(node);
        this.notifyChange();
    }

    handleLabelChange(event) {
        const node = this.nodeFor(event.target.dataset.id);
        if (!node) {
            return;
        }
        const newKey = event.target.value;
        if (!this.applyRename(node, newKey)) {
            // Only a rename that reached the JSON counts, so a rejected one
            // (empty or duplicate key) leaves the outline as it was.
            return;
        }
        this.refreshRow(node);
        this.notifyChange();
    }

    // If a rename could not be applied (empty or duplicate key), snap the
    // textbox back to the key actually stored in the JSON when leaving it.
    handleLabelBlur(event) {
        const node = this.nodeFor(event.target.dataset.id);
        if (node && event.target.value !== node.key) {
            event.target.value = node.key;
        }
    }

    /**
     * Renames an object key. Key order needs no special handling any more:
     * the tree holds children in order, so renaming one is just a relabel.
     * Returns false when the new key is empty or already taken by a sibling.
     */
    applyRename(node, newKey) {
        if (newKey === node.key) {
            return false;
        }
        if (!newKey || this.hasSibling(node.parent, newKey, node)) {
            return false;
        }
        node.key = newKey;
        return true;
    }

    hasSibling(parent, key, except) {
        return parent.children.some(
            (child) => child !== except && child.key === key
        );
    }

    /**
     * Converts the textbox string back to the value's original JSON type so
     * numbers stay numbers and booleans stay booleans. Falls back to the raw
     * string when the text no longer parses as that type.
     */
    coerce(raw, valueType) {
        if (valueType === TYPE_NUMBER) {
            const n = Number(raw);
            return raw.trim() !== '' && !Number.isNaN(n) ? n : raw;
        }
        if (valueType === TYPE_BOOLEAN) {
            const lowered = raw.trim().toLowerCase();
            if (lowered === 'true') {
                return true;
            }
            if (lowered === 'false') {
                return false;
            }
            return raw;
        }
        if (valueType === TYPE_NULL) {
            return raw === '' ? null : raw;
        }
        return raw;
    }

    /** The validation message for a field, or undefined when it is fine.
     *  Text and empty fields can hold anything, so only numbers and booleans
     *  can fail — that is the whole of "the type it arrived with". */
    errorFor(node, text) {
        if (!this._validateTypes) {
            return undefined;
        }
        if (node.valueType === TYPE_NUMBER) {
            return text.trim() !== '' && !Number.isNaN(Number(text))
                ? undefined
                : 'Enter a number.';
        }
        if (node.valueType === TYPE_BOOLEAN) {
            const lowered = text.trim().toLowerCase();
            return lowered === 'true' || lowered === 'false'
                ? undefined
                : 'Enter true or false.';
        }
        return undefined;
    }

    revalidate() {
        this.eachNode((node) => {
            if (node.kind === KIND_LEAF) {
                node.error = this.errorFor(node, node.text);
            }
        });
    }

    invalidNodes() {
        const invalid = [];
        this.eachNode((node) => {
            if (node.error) {
                invalid.push(node);
            }
        });
        return invalid;
    }

    eachNode(callback) {
        const walk = (node) => {
            callback(node);
            if (node.children) {
                node.children.forEach(walk);
            }
        };
        if (this._root) {
            walk(this._root);
        }
    }

    // ---------------------------------------------------------------------
    // Collapse and search
    // ---------------------------------------------------------------------

    handleToggleCollapse(event) {
        const node = this.nodeFor(event.target.dataset.id);
        if (node) {
            node.collapsed = !node.collapsed;
            this.rebuildRows();
        }
    }

    handleExpandAll() {
        this.setCollapsedAll(false);
    }

    handleCollapseAll() {
        this.setCollapsedAll(true);
    }

    setCollapsedAll(collapsed) {
        this.eachNode((node) => {
            if (node.kind !== KIND_LEAF && node !== this._root) {
                node.collapsed = collapsed;
            }
        });
        this.rebuildRows();
    }

    handleSearch(event) {
        this._searchTerm = (event.target.value || '').trim();
        this.rebuildRows();
    }

    // ---------------------------------------------------------------------
    // Adding and deleting
    // ---------------------------------------------------------------------

    handleAddClick(event) {
        this.openAddForm(event.target.dataset.id);
    }

    handleAddRootClick() {
        this.openAddForm(this._root.id);
    }

    openAddForm(nodeId) {
        this._addTargetId = nodeId;
        this._addName = '';
        this._addType = TYPE_TEXT;
        this._addContainerKind = KIND_OBJECT;
        this._addError = undefined;
        this._confirmDeleteId = undefined;
        this.rebuildRows();
    }

    handleAddCancel() {
        this._addTargetId = undefined;
        this._addError = undefined;
        this.rebuildRows();
    }

    handleAddNameChange(event) {
        this._addName = event.target.value;
    }

    handleAddTypeChange(event) {
        this._addType = event.detail.value;
    }

    handleAddContainerChange(event) {
        this._addContainerKind = event.detail.value;
        // Whether a name is needed depends on this, so the form must redraw.
        this.rebuildRows();
    }

    handleAddConfirm() {
        const parent = this.nodeFor(this._addTargetId);
        if (!parent) {
            return;
        }
        // Adding under a leaf converts it into a container first (JF-13).
        const converting = parent.kind === KIND_LEAF;
        const containerKind = converting ? this._addContainerKind : parent.kind;
        const named = containerKind === KIND_OBJECT;
        const key = (this._addName || '').trim();
        if (named && !key) {
            this._addError = 'Give the field a name.';
            this.rebuildRows();
            return;
        }
        // A freshly converted leaf has no children, so it can have no clash.
        if (named && !converting && this.hasSibling(parent, key)) {
            this._addError = `This group already has a field called "${key}".`;
            this.rebuildRows();
            return;
        }

        if (converting) {
            this.convertToContainer(parent, containerKind);
        }
        parent.children.push(
            this.createNode(
                named ? key : parent.children.length,
                this._addType,
                parent
            )
        );
        // A group the user just added to should not stay closed over it.
        parent.collapsed = false;
        this._addTargetId = undefined;
        this._addError = undefined;
        this.rebuildRows();
        this.notifyChange();
    }

    /**
     * Turns a leaf into an empty group or list in place. The node keeps its
     * identity — same id, same key, same baseline key — so it is still the
     * same field, now holding structure instead of a scalar. The scalar and
     * any confidence envelope that described it are dropped: the envelope
     * measured a value that no longer exists.
     */
    convertToContainer(node, kind) {
        node.kind = kind;
        node.children = [];
        node.collapsed = false;
        node.converted = true;
        node.value = undefined;
        node.text = undefined;
        node.baselineText = undefined;
        node.valueType = undefined;
        node.envelope = undefined;
        node.error = undefined;
    }

    /** A brand-new node: no baselines, so it renders as edited from birth. */
    createNode(key, type, parent) {
        const isArrayItem = parent.kind === KIND_ARRAY;
        const node = {
            id: String(this._idCounter++),
            key,
            baselineKey: null,
            isArrayItem,
            isNew: true,
            parent,
            collapsed: false,
            envelope: undefined,
            error: undefined
        };
        this._nodesById.set(node.id, node);
        if (type === KIND_OBJECT || type === KIND_ARRAY) {
            node.kind = type;
            node.children = [];
        } else {
            node.kind = KIND_LEAF;
            node.valueType = type;
            if (type === TYPE_NUMBER) {
                node.value = 0;
            } else if (type === TYPE_BOOLEAN) {
                node.value = false;
            } else if (type === TYPE_NULL) {
                node.value = null;
            } else {
                node.value = '';
            }
            node.text = node.value === null ? '' : String(node.value);
            node.baselineText = null;
            node.error = this.errorFor(node, node.text);
        }
        return node;
    }

    handleDeleteClick(event) {
        const node = this.nodeFor(event.target.dataset.id);
        if (!node) {
            return;
        }
        // Losing a whole subtree in one click is worth a question; losing one
        // field is not — it is visibly gone and the JSON is still on screen.
        if (node.kind !== KIND_LEAF && node.children.length > 0) {
            this._confirmDeleteId = node.id;
            this._addTargetId = undefined;
            this.rebuildRows();
            return;
        }
        this.removeNode(node);
    }

    handleDeleteConfirm(event) {
        const node = this.nodeFor(event.target.dataset.id);
        if (node) {
            this.removeNode(node);
        }
    }

    handleDeleteCancel() {
        this._confirmDeleteId = undefined;
        this.rebuildRows();
    }

    removeNode(node) {
        const siblings = node.parent.children;
        const at = siblings.indexOf(node);
        if (at < 0) {
            return;
        }
        siblings.splice(at, 1);
        this.forget(node);
        // Array item keys are positional; re-key the survivors so serialize
        // and the "Item n" labels stay in step.
        if (node.parent.kind === KIND_ARRAY) {
            siblings.forEach((sibling, index) => {
                sibling.key = index;
            });
        }
        this._confirmDeleteId = undefined;
        this._addTargetId = undefined;
        this.rebuildRows();
        this.notifyChange();
    }

    // ---------------------------------------------------------------------
    // Plumbing
    // ---------------------------------------------------------------------

    /** Nodes are looked up by id on every keystroke, so they are indexed as
     *  they are built rather than found by walking the tree each time. */
    nodeFor(id) {
        if (id === undefined || id === null) {
            return undefined;
        }
        return this._nodesById.get(id);
    }

    /** Drops a detached node and its descendants from the index, so a stale
     *  id can never resolve to a node that is no longer in the tree. */
    forget(node) {
        this._nodesById.delete(node.id);
        if (node.children) {
            node.children.forEach((child) => this.forget(child));
        }
    }

    notifyChange() {
        // One walk of the tree, not three: getJson(), getJsonString() and
        // jsonOutput would each re-serialize it on every keystroke.
        const value = this.getJson();
        this.dispatchEvent(
            new CustomEvent('jsonchange', {
                detail: {
                    value,
                    jsonString: JSON.stringify(value, null, 3),
                    valid: this.isValid
                }
            })
        );
        // Keep the jsonOutput Flow attribute in sync (no-op outside Flow)
        this.dispatchEvent(
            new FlowAttributeChangeEvent(
                'jsonOutput',
                value === undefined ? '' : JSON.stringify(value)
            )
        );
    }
}
