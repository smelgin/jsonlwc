import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

/** Base class of a label textbox. */
const LABEL_INPUT_CLASS = 'label-input';

/** Base class of a value textbox. */
const VALUE_INPUT_CLASS = 'value-input';

/** Marks a textbox holding something other than what it loaded with. */
const MODIFIED_CLASS = 'field-modified';

/** Marks a textbox whose value no longer parses as its loaded type. */
const INVALID_CLASS = 'field-invalid';

/** Node holding named members. */
const KIND_OBJECT = 'object';

/** Node holding positional members. */
const KIND_ARRAY = 'array';

/** Node holding a scalar value. */
const KIND_LEAF = 'leaf';

/** Leaf carrying text. */
const TYPE_TEXT = 'string';

/** Leaf carrying a number. */
const TYPE_NUMBER = 'number';

/** Leaf carrying true or false. */
const TYPE_BOOLEAN = 'boolean';

/** Leaf carrying nothing at all. */
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

/** Confidence at or above which a field counts as reliable. */
const DEFAULT_CONFIDENCE_THRESHOLD = 0.8;

/**
 * Reads a boolean the way Flow and App Builder supply it, as the strings
 * "true" and "false" rather than as a boolean.
 *
 * @param {boolean|string} value Value as the host set it.
 * @returns {boolean} Whether the flag is on.
 */
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
 *
 * @module jsonForm
 * @extends LightningElement
 */
export default class JsonForm extends LightningElement {
    /** Flattened, currently visible rows of the tree. */
    rows = [];

    /** Field types offered when adding a field. */
    typeOptions = TYPE_OPTIONS;

    /** Container kinds a leaf may be converted into. */
    containerOptions = CONTAINER_OPTIONS;

    /** Root of the node tree; undefined for a scalar document. */
    _root;

    /** The document itself when it is a bare scalar. */
    _scalar;

    /** Rendered rows by node id, for in-place refreshes. */
    _rowsById = new Map();

    /** Every node by id, so a keystroke resolves without a tree walk. */
    _nodesById = new Map();

    /** Source of the next node id. */
    _idCounter = 0;

    /** Document as a string, when the host set it that way. */
    _jsonInput;

    /** Whether object keys may be renamed. */
    _editLabels = false;

    /** Whether fields may be added and deleted. */
    _editStructure = false;

    /** Whether groups and lists may be collapsed. */
    _collapsible = false;

    /** Whether the search box is shown. */
    _searchable = false;

    /** Whether confidence envelopes are unwrapped and badged. */
    _showConfidence = false;

    /** Whether values are checked against their loaded type. */
    _validateTypes = false;

    /** Confidence below which a field is badged in red. */
    _confidenceThreshold = DEFAULT_CONFIDENCE_THRESHOLD;

    /** Current search term, empty when nothing is being filtered. */
    _searchTerm = '';

    /** Node the add form is open on. */
    _addTargetId;

    /** Name typed into the add form. */
    _addName = '';

    /** Type chosen in the add form. */
    _addType = TYPE_TEXT;

    /** Container kind a leaf would be converted into. */
    _addContainerKind = KIND_OBJECT;

    /** Why the add form cannot be confirmed. */
    _addError;

    /** Node whose deletion is awaiting confirmation. */
    _confirmDeleteId;

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

    /**
     * Returns the current, possibly modified, JSON as a formatted string.
     *
     * @param {number} [indent] Spaces per level; three by default.
     * @returns {string} The document, pretty-printed.
     */
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

    /**
     * Loads a document, discarding whatever was being edited.
     *
     * Unparseable text leaves the form empty rather than throwing, since the
     * host may be typing the document in.
     *
     * @param {object|string} value Document as an object or a JSON string.
     */
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
     * Builds one node and its descendants.
     *
     * Array items have no name of their own, so their baseline key stays
     * null and a positional label is rendered instead.
     *
     * @param {*} raw Member of the document this node represents.
     * @param {string|number} key Object key the node sits under, or its
     *        index when the parent is an array.
     * @param {boolean} isArrayItem Whether the parent is a list.
     * @param {object} parent Node this one hangs off; null at the root.
     * @returns {object} The new node, already indexed.
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
     * Decides whether a member is a confidence envelope.
     *
     * Only the exact two-key {value, confidence} shape qualifies, so a
     * legitimate business field named "value" can never be swallowed. Kept
     * deliberately identical to IdpJsonReader.isEnvelope.
     *
     * @param {*} node Member of the document to inspect.
     * @returns {boolean} True when it wraps a value.
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

    /**
     * Rebuilds the JSON from the tree, restoring any envelope it came in.
     *
     * @param {object} node Node to serialize, with its descendants.
     * @returns {*} That subtree as plain JSON.
     */
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

    /**
     * Rebuilds the visible rows from the tree, honouring search and collapse.
     */
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

    /**
     * Walks one node's children, appending the rows that should be visible.
     *
     * @param {object} node Node whose children are being walked.
     * @param {number} level Indentation depth of those children.
     * @param {Array<object>} rows Accumulator the rows are pushed onto.
     * @param {object} [matches] Search hits; undefined when not searching.
     * @param {boolean} ancestorMatched Whether an ancestor matched, which
     *        keeps a matched group's whole subtree visible.
     */
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

    /**
     * Finds the nodes the search term reaches.
     *
     * @returns {{self:Set,descendant:Set}} Ids of the nodes that match, and
     *          of those with a matching descendant, kept so a match is shown
     *          in context.
     */
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

    /**
     * Names a node: its key, or its position when the parent is a list.
     *
     * @param {object} node Node to label.
     * @param {number} index Position among its siblings.
     * @returns {string} Label shown to the user.
     */
    labelOf(node, index) {
        return node.isArrayItem ? `Item ${index + 1}` : String(node.key);
    }

    /**
     * Builds the row a template renders for one node.
     *
     * @param {object} node Node to render.
     * @param {number} index Position among its siblings.
     * @param {number} level Indentation depth.
     * @returns {object} The row, also indexed for later in-place refreshes.
     */
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

    /**
     * Names the add action for a node, which depends on what it holds.
     *
     * @param {object} node Node the add button sits on.
     * @returns {string} Button title.
     */
    addTitleFor(node) {
        if (node.kind === KIND_ARRAY) {
            return 'Add item';
        }
        return node.kind === KIND_OBJECT ? 'Add field' : 'Add child field';
    }

    /**
     * Warns before a leaf is turned into a container.
     *
     * The value it holds is named outright, because adding the child
     * discards it.
     *
     * @param {object} node Leaf about to be converted.
     * @returns {string} Warning shown in the add form.
     */
    conversionMessageFor(node) {
        const held =
            node.text === '' || node.text === undefined
                ? 'its empty value'
                : `"${node.text}"`;
        return `This field holds a value. Adding a child turns it into a container and discards ${held}.`;
    }

    /**
     * Labels a container with what it holds.
     *
     * @param {object} node Group or list node.
     * @returns {string} Badge text.
     */
    badgeFor(node) {
        if (node.kind === KIND_ARRAY) {
            const count = node.children.length;
            return `List · ${count} item${count === 1 ? '' : 's'}`;
        }
        return 'Group';
    }

    /**
     * Asks before a subtree is deleted.
     *
     * @param {object} node Node about to be deleted.
     * @returns {string|undefined} The question, or undefined when the node
     *          holds nothing worth confirming.
     */
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
     *
     * @param {object} row Row to decorate.
     * @param {object} node Node the row renders.
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

    /**
     * Re-decorates one row in place.
     *
     * Reassigns `rows` only when something visible actually changed, so
     * typing does not re-render the whole form.
     *
     * @param {object} node Node whose row is refreshed.
     */
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

    /** Whether anything is currently visible. */
    get hasRows() {
        return this.rows.length > 0;
    }

    /** Whether the toolbar has anything to offer. */
    get hasToolbar() {
        return this._searchable || this._collapsible || this.canAddToRoot;
    }

    /** Whether a field may be added at the top level. */
    get canAddToRoot() {
        return this._editStructure && !!this._root;
    }

    /** Whether the add form is open at the top level. */
    get isAddingToRoot() {
        return !!this._root && this._addTargetId === this._root.id;
    }

    /** Whether a field added at the top level needs a name. */
    get rootNeedsName() {
        return !!this._root && this._root.kind === KIND_OBJECT;
    }

    /** Name currently typed into the add form. */
    get addName() {
        return this._addName;
    }

    /** Type currently chosen in the add form. */
    get addType() {
        return this._addType;
    }

    /** Why the add form cannot be confirmed. */
    get addError() {
        return this._addError;
    }

    /** Current search term. */
    get searchTerm() {
        return this._searchTerm;
    }

    /** Whether a search is running and found nothing. */
    get noMatches() {
        return !this.hasRows && !!this._searchTerm;
    }

    /** Whether the form holds no document at all. */
    get isEmpty() {
        return !this.hasRows && !this._searchTerm;
    }

    /**
     * Applies an edit to one field's value.
     *
     * @param {Event} event Change event from a value textbox.
     */
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

    /**
     * Applies a rename to one field's key.
     *
     * @param {Event} event Change event from a label textbox.
     */
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

    /**
     * Snaps a label textbox back to the key actually stored in the JSON, so
     * a rename that was refused does not linger on screen.
     *
     * @param {FocusEvent} event Blur event from a label textbox.
     */
    handleLabelBlur(event) {
        const node = this.nodeFor(event.target.dataset.id);
        if (node && event.target.value !== node.key) {
            event.target.value = node.key;
        }
    }

    /**
     * Renames an object key.
     *
     * Key order needs no special handling: the tree holds children in order,
     * so renaming one is just a relabel.
     *
     * @param {object} node Node being renamed.
     * @param {string} newKey Key the user typed.
     * @returns {boolean} False when the key is empty, unchanged, or already
     *          taken by a sibling.
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

    /**
     * Reports whether a key is already taken among a node's children.
     *
     * @param {object} parent Node whose children are checked.
     * @param {string} key Key being claimed.
     * @param {object} [except] Node allowed to keep the key, when renaming.
     * @returns {boolean} True when the key clashes.
     */
    hasSibling(parent, key, except) {
        return parent.children.some(
            (child) => child !== except && child.key === key
        );
    }

    /**
     * Converts the textbox string back to the value's original JSON type so
     * numbers stay numbers and booleans stay booleans.
     *
     * @param {string} raw Text as typed.
     * @param {string} valueType Type the field arrived with.
     * @returns {*} The typed value, or the raw string when the text no
     *          longer parses as that type.
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

    /**
     * Checks a field against the type it arrived with.
     *
     * Text and empty fields can hold anything, so only numbers and booleans
     * can fail — that is the whole of "the type it arrived with".
     *
     * @param {object} node Node being checked.
     * @param {string} text Text as typed.
     * @returns {string|undefined} The message to show, or undefined when the
     *          field is fine.
     */
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

    /**
     * Re-checks every field, after validation is switched on or off.
     */
    revalidate() {
        this.eachNode((node) => {
            if (node.kind === KIND_LEAF) {
                node.error = this.errorFor(node, node.text);
            }
        });
    }

    /**
     * Collects the fields currently failing validation.
     *
     * @returns {Array<object>} Nodes carrying an error.
     */
    invalidNodes() {
        const invalid = [];
        this.eachNode((node) => {
            if (node.error) {
                invalid.push(node);
            }
        });
        return invalid;
    }

    /**
     * Visits every node of the tree, root included.
     *
     * @param {Function} callback Called once per node.
     */
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

    /**
     * Collapses or expands one group.
     *
     * @param {Event} event Click event from a toggle button.
     */
    handleToggleCollapse(event) {
        const node = this.nodeFor(event.target.dataset.id);
        if (node) {
            node.collapsed = !node.collapsed;
            this.rebuildRows();
        }
    }

    /**
     * Expands every group.
     */
    handleExpandAll() {
        this.setCollapsedAll(false);
    }

    /**
     * Collapses every group.
     */
    handleCollapseAll() {
        this.setCollapsedAll(true);
    }

    /**
     * Collapses or expands every group at once.
     *
     * @param {boolean} collapsed Whether groups end up closed.
     */
    setCollapsedAll(collapsed) {
        this.eachNode((node) => {
            if (node.kind !== KIND_LEAF && node !== this._root) {
                node.collapsed = collapsed;
            }
        });
        this.rebuildRows();
    }

    /**
     * Filters the form by field name or value.
     *
     * @param {Event} event Change event from the search box.
     */
    handleSearch(event) {
        this._searchTerm = (event.target.value || '').trim();
        this.rebuildRows();
    }

    /**
     * Opens the add form under one node.
     *
     * @param {Event} event Click event from an add button.
     */
    handleAddClick(event) {
        this.openAddForm(event.target.dataset.id);
    }

    /**
     * Opens the add form at the top level.
     */
    handleAddRootClick() {
        this.openAddForm(this._root.id);
    }

    /**
     * Opens the add form on a node, clearing whatever it last held.
     *
     * @param {string} nodeId Node the new field goes under.
     */
    openAddForm(nodeId) {
        this._addTargetId = nodeId;
        this._addName = '';
        this._addType = TYPE_TEXT;
        this._addContainerKind = KIND_OBJECT;
        this._addError = undefined;
        this._confirmDeleteId = undefined;
        this.rebuildRows();
    }

    /**
     * Closes the add form without adding anything.
     */
    handleAddCancel() {
        this._addTargetId = undefined;
        this._addError = undefined;
        this.rebuildRows();
    }

    /**
     * Tracks the name typed into the add form.
     *
     * @param {Event} event Change event from the name textbox.
     */
    handleAddNameChange(event) {
        this._addName = event.target.value;
    }

    /**
     * Tracks the type chosen in the add form.
     *
     * @param {CustomEvent} event Change event from the type picker.
     */
    handleAddTypeChange(event) {
        this._addType = event.detail.value;
    }

    /**
     * Tracks the container kind a leaf would be converted into.
     *
     * @param {CustomEvent} event Change event from the container picker.
     */
    handleAddContainerChange(event) {
        this._addContainerKind = event.detail.value;
        // Whether a name is needed depends on this, so the form must redraw.
        this.rebuildRows();
    }

    /**
     * Adds the field the user described, converting a leaf into a container
     * first when the field is going underneath one.
     */
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
     *
     * @param {object} node Leaf being converted.
     * @param {string} kind Container kind it becomes.
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

    /**
     * Builds a brand-new node, with no baselines, so it renders as edited
     * from birth.
     *
     * @param {string|number} key Key or position the node takes.
     * @param {string} type Field type or container kind.
     * @param {object} parent Node it goes under.
     * @returns {object} The new node, already indexed.
     */
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

    /**
     * Deletes a field, asking first when a whole subtree would go with it.
     *
     * @param {Event} event Click event from a delete button.
     */
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

    /**
     * Deletes the subtree the user has just confirmed.
     *
     * @param {Event} event Click event from the confirm button.
     */
    handleDeleteConfirm(event) {
        const node = this.nodeFor(event.target.dataset.id);
        if (node) {
            this.removeNode(node);
        }
    }

    /**
     * Keeps the subtree the user decided against deleting.
     */
    handleDeleteCancel() {
        this._confirmDeleteId = undefined;
        this.rebuildRows();
    }

    /**
     * Detaches a node from the tree and re-keys list siblings after it.
     *
     * @param {object} node Node to remove.
     */
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

    /**
     * Resolves a node by id.
     *
     * Nodes are looked up on every keystroke, so they are indexed as they
     * are built rather than found by walking the tree each time.
     *
     * @param {string} id Node id, as carried on the element's dataset.
     * @returns {object|undefined} The node, or undefined when it is gone.
     */
    nodeFor(id) {
        if (id === undefined || id === null) {
            return undefined;
        }
        return this._nodesById.get(id);
    }

    /**
     * Drops a detached node and its descendants from the index, so a stale
     * id can never resolve to a node that is no longer in the tree.
     *
     * @param {object} node Node that has left the tree.
     */
    forget(node) {
        this._nodesById.delete(node.id);
        if (node.children) {
            node.children.forEach((child) => this.forget(child));
        }
    }

    /**
     * Emits the edited document and refreshes the Flow output attribute.
     */
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
