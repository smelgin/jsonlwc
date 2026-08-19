import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import listSets from '@salesforce/apex/IdpConfiguratorController.listSets';
import readSet from '@salesforce/apex/IdpConfiguratorController.readSet';
import check from '@salesforce/apex/IdpConfiguratorController.check';
import saveSet from '@salesforce/apex/IdpConfiguratorController.saveSet';
import pickers from '@salesforce/apex/IdpConfiguratorController.pickers';
import fieldsOf from '@salesforce/apex/IdpConfiguratorController.fieldsOf';

/**
 * Edits one document type's mapping rules.
 *
 * The form is the primary view and the raw JSON is the escape hatch. Both
 * edit the same definition, so switching tabs serialises one into the
 * other rather than keeping two drafts: `model` is the truth while the
 * form shows, `draftJson` while the Advanced tab does.
 *
 * Saving custom metadata is a Metadata API deployment, so it is
 * asynchronous: saveSet() returns once the deployment is queued, not once
 * it has landed. Rather than claim success at that point, this component
 * polls the stored definition until it matches what was sent. POLL_MS and
 * POLL_LIMIT bound the wait at roughly a minute, after which the admin is
 * told to check back rather than left watching a spinner.
 */
const POLL_MS = 2000;
const POLL_LIMIT = 30;

const SECTION_TYPES = [
    { label: 'Fixed — writes one record', value: 'Fixed' },
    { label: 'Repeating — one record per row', value: 'Repeating' }
];
const POLICIES = [
    { label: 'Always', value: 'Always' },
    { label: 'Only if blank', value: 'Only if blank' }
];
const MODES = [
    { label: "Follow the run's mode", value: '' },
    { label: 'Extraction — write the value', value: 'Extraction' },
    { label: 'Compliance — compare and report', value: 'Compliance' }
];
const GRADES = [
    { label: 'Inferred (default)', value: '' },
    { label: 'Exact only', value: 'Exact' }
];

/** Keys the engine understands, in the order they read best. */
const RULE_KEYS = [
    'name',
    'label',
    'jsonPath',
    'targetField',
    'valueTypeName',
    'mode',
    'overwritePolicy',
    'minGrade',
    'minConfidence',
    'required',
    'anchorFilter',
    'active'
];
const SECTION_KEYS = [
    'name',
    'label',
    'sectionType',
    'targetObject',
    'rowPath',
    'matchField',
    'matchValue',
    'recordFilter',
    'parentSection',
    'active'
];

let uid = 0;
const nextKey = () => `k${(uid += 1)}`;

export default class IdpConfigurator extends LightningElement {
    @track sets = [];
    @track findings = [];
    @track model = []; // sections, each with .rules
    @track objectOptions = [];
    @track valueTypeOptions = [];

    selectedName;
    label;
    draftJson = '';
    savedJson = '';
    activeTab = 'form';

    loading = false;
    saving = false;
    error;

    fieldCache = {}; // objectName -> FieldOption[]
    pollCount = 0;
    pollTimer;

    sectionTypeOptions = SECTION_TYPES;
    policyOptions = POLICIES;
    modeOptions = MODES;
    gradeOptions = GRADES;

    connectedCallback() {
        this.bootstrap();
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    async bootstrap() {
        this.loading = true;
        try {
            const [vocabulary, sets] = await Promise.all([
                pickers(),
                listSets()
            ]);
            this.objectOptions = vocabulary.objects;
            this.valueTypeOptions = [
                { label: 'Derive from the field', value: '' },
                ...vocabulary.valueTypes
            ];
            this.sets = sets;
            if (sets.length) {
                await this.open(sets[0].name);
            }
        } catch (e) {
            this.error = this.messageOf(e);
        } finally {
            this.loading = false;
        }
    }

    async open(name) {
        this.loading = true;
        this.error = undefined;
        try {
            const detail = await readSet({ developerName: name });
            this.selectedName = detail.name;
            this.label = detail.label;
            this.savedJson = detail.definition;
            this.draftJson = detail.definition;
            this.findings = detail.findings || [];
            const seeded = { ...this.fieldCache };
            (detail.schema || []).forEach((entry) => {
                seeded[entry.objectName] = entry.fields;
            });
            this.fieldCache = seeded;
            this.model = this.toModel(detail.definition);
            await this.warmFieldCache();
        } catch (e) {
            this.error = this.messageOf(e);
        } finally {
            this.loading = false;
        }
    }

    // ───────────────────────── model ⇄ json ─────────────────────────

    /** JSON text into the editable model, tagging every row with a stable
     *  key so re-renders do not lose focus mid-typing. */
    toModel(json) {
        let parsed;
        try {
            parsed = JSON.parse(json);
        } catch {
            return [];
        }
        const sections = (parsed && parsed.sections) || [];
        return sections.map((section) => ({
            ...section,
            key: nextKey(),
            sectionType: section.sectionType || 'Fixed',
            active: section.active !== false,
            rules: (section.rules || []).map((rule) => ({
                ...rule,
                key: nextKey(),
                active: rule.active !== false,
                required: rule.required === true
            }))
        }));
    }

    /** The model back to the JSON the engine reads: keys in a fixed order,
     *  empty values dropped so the stored definition stays readable. */
    toJson() {
        const sections = this.model.map((section) => {
            const out = {};
            SECTION_KEYS.forEach((key) => {
                if (key === 'active') {
                    if (section.active === false) {
                        out.active = false;
                    }
                    return;
                }
                const value = section[key];
                if (value !== undefined && value !== null && value !== '') {
                    out[key] = value;
                }
            });
            out.rules = (section.rules || []).map((rule) => {
                const row = {};
                RULE_KEYS.forEach((key) => {
                    const value = rule[key];
                    if (key === 'active') {
                        if (rule.active === false) {
                            row.active = false;
                        }
                        return;
                    }
                    if (key === 'required') {
                        if (rule.required === true) {
                            row.required = true;
                        }
                        return;
                    }
                    if (key === 'minConfidence') {
                        if (
                            value !== undefined &&
                            value !== null &&
                            value !== ''
                        ) {
                            row.minConfidence = Number(value);
                        }
                        return;
                    }
                    if (value !== undefined && value !== null && value !== '') {
                        row[key] = value;
                    }
                });
                return row;
            });
            return out;
        });
        return JSON.stringify({ sections }, null, 2);
    }

    /** Whichever view is showing owns the truth; read it before acting. */
    currentJson() {
        return this.activeTab === 'json' ? this.draftJson : this.toJson();
    }

    handleTabChange(event) {
        const target = event.target.value;
        if (target === 'json' && this.activeTab !== 'json') {
            this.draftJson = this.toJson(); // form → text
        } else if (target === 'form' && this.activeTab === 'json') {
            try {
                JSON.parse(this.draftJson);
            } catch {
                this.toast(
                    'That JSON does not parse',
                    'The form cannot show it. Fix the text, or press Check for the exact problem.',
                    'warning'
                );
                return; // stay on the Advanced tab
            }
            this.model = this.toModel(this.draftJson); // text → form
            this.warmFieldCache();
        }
        this.activeTab = target;
    }

    // ───────────────────────── field pickers ────────────────────────

    async warmFieldCache() {
        const wanted = [
            ...new Set(this.model.map((s) => s.targetObject).filter(Boolean))
        ].filter((name) => !this.fieldCache[name]);
        if (!wanted.length) {
            return;
        }
        const loaded = await Promise.all(
            wanted.map((name) =>
                fieldsOf({ objectName: name })
                    .then((fields) => ({ name, fields }))
                    .catch(() => ({ name, fields: [] }))
            )
        );
        const merged = { ...this.fieldCache };
        loaded.forEach(({ name, fields }) => {
            merged[name] = fields;
        });
        this.fieldCache = merged;
        this.model = [...this.model]; // re-render the pickers
    }

    fieldOptions(objectName, writableOnly) {
        const fields = this.fieldCache[objectName] || [];
        const usable = writableOnly
            ? fields.filter((f) => f.updateable)
            : fields;
        return usable.map((f) => ({ label: f.label, value: f.value }));
    }

    // ───────────────────────────── editing ──────────────────────────

    locate(event) {
        const sectionKey = event.target.dataset.section;
        const ruleKey = event.target.dataset.rule;
        const section = this.model.find((s) => s.key === sectionKey);
        if (!section) {
            return {};
        }
        const rule = ruleKey
            ? section.rules.find((r) => r.key === ruleKey)
            : null;
        return { section, rule };
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        const { section, rule } = this.locate(event);
        if (!section) {
            return;
        }
        const target = rule || section;
        let value;
        if (
            event.target.type === 'checkbox' ||
            event.target.type === 'toggle'
        ) {
            value = event.target.checked;
        } else if (event.detail && 'value' in event.detail) {
            value = event.detail.value;
        } else {
            value = event.target.value;
        }
        target[field] = value;
        // Fields belong to the object, so changing it invalidates every pick.
        if (!rule && field === 'targetObject') {
            section.matchField = '';
            section.rules.forEach((r) => {
                r.targetField = '';
            });
            this.warmFieldCache();
        }
        this.model = [...this.model];
    }

    handleAddSection() {
        this.model = [
            ...this.model,
            {
                key: nextKey(),
                name: `Section_${this.model.length + 1}`,
                label: '',
                sectionType: 'Fixed',
                targetObject: '',
                active: true,
                rules: []
            }
        ];
    }

    handleAddRule(event) {
        const { section } = this.locate(event);
        if (!section) {
            return;
        }
        section.rules = [
            ...section.rules,
            {
                key: nextKey(),
                name: `${section.name || 'Rule'}_${section.rules.length + 1}`,
                label: '',
                jsonPath: '',
                targetField: '',
                overwritePolicy: 'Always',
                active: true,
                required: false
            }
        ];
        this.model = [...this.model];
    }

    handleDeleteSection(event) {
        const { section } = this.locate(event);
        if (!section) {
            return;
        }
        const count = section.rules.length;
        const plural = count === 1 ? '' : 's';
        if (
            count &&
            // eslint-disable-next-line no-alert
            !window.confirm(
                `Delete section "${section.name}" and its ${count} rule${plural}?`
            )
        ) {
            return;
        }
        this.model = this.model.filter((s) => s.key !== section.key);
    }

    handleDeleteRule(event) {
        const { section, rule } = this.locate(event);
        if (!section || !rule) {
            return;
        }
        section.rules = section.rules.filter((r) => r.key !== rule.key);
        this.model = [...this.model];
    }

    handleJsonChange(event) {
        this.draftJson = event.target.value;
    }

    handleFormat() {
        try {
            this.draftJson = JSON.stringify(
                JSON.parse(this.draftJson),
                null,
                2
            );
        } catch (e) {
            this.toast('Cannot tidy invalid JSON', e.message, 'warning');
        }
    }

    // ─────────────────────── check, save, revert ────────────────────

    async handleCheck() {
        this.error = undefined;
        try {
            this.findings = await check({
                developerName: this.selectedName,
                definition: this.currentJson()
            });
            if (!this.findings.length) {
                this.toast(
                    'Looks good',
                    'This definition loads cleanly.',
                    'success'
                );
            }
        } catch (e) {
            this.error = this.messageOf(e);
        }
    }

    async handleSave() {
        this.saving = true;
        this.error = undefined;
        const submitted = this.currentJson();
        try {
            await saveSet({
                developerName: this.selectedName,
                definition: submitted
            });
            this.startPolling(submitted);
        } catch (e) {
            this.saving = false;
            this.error = this.messageOf(e);
        }
    }

    handleRevert() {
        this.draftJson = this.savedJson;
        this.model = this.toModel(this.savedJson);
        this.findings = [];
        this.warmFieldCache();
    }

    handleSelect(event) {
        const name = event.currentTarget.dataset.name;
        if (name === this.selectedName) {
            return;
        }
        // eslint-disable-next-line no-alert
        if (this.dirty && !window.confirm('Discard unsaved changes?')) {
            return;
        }
        this.open(name);
    }

    // ──────────────────── waiting for the deployment ────────────────

    startPolling(submitted) {
        this.stopPolling();
        this.pollCount = 0;
        // A metadata deployment reports no completion event to the browser, so
        // watching for the saved value to appear is the only way to know it
        // landed. Cleared on success, on timeout and in disconnectedCallback.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollTimer = setInterval(async () => {
            this.pollCount += 1;
            try {
                const detail = await readSet({
                    developerName: this.selectedName
                });
                if (this.sameJson(detail.definition, submitted)) {
                    this.stopPolling();
                    this.saving = false;
                    this.savedJson = detail.definition;
                    this.draftJson = detail.definition;
                    this.model = this.toModel(detail.definition);
                    this.findings = detail.findings || [];
                    this.toast(
                        'Saved',
                        `${this.label} has been updated.`,
                        'success'
                    );
                    this.warmFieldCache();
                    listSets().then((sets) => {
                        this.sets = sets;
                    });
                    return;
                }
            } catch {
                // A read failing mid-deployment is not itself a failure; keep waiting.
            }
            if (this.pollCount >= POLL_LIMIT) {
                this.stopPolling();
                this.saving = false;
                this.toast(
                    'Still deploying',
                    'The save was queued but has not landed yet. Reopen this document type in a moment to confirm.',
                    'warning'
                );
            }
        }, POLL_MS);
    }

    stopPolling() {
        if (this.pollTimer) {
            clearInterval(this.pollTimer);
            this.pollTimer = undefined;
        }
    }

    /** Compares meaning, not whitespace — the platform may reformat. */
    sameJson(a, b) {
        try {
            return (
                JSON.stringify(JSON.parse(a)) === JSON.stringify(JSON.parse(b))
            );
        } catch {
            return a === b;
        }
    }

    // ───────────────────────────── getters ──────────────────────────

    get setRows() {
        return this.sets.map((entry) => ({
            ...entry,
            counts:
                entry.sectionCount === null || entry.sectionCount === undefined
                    ? 'unreadable'
                    : `${entry.sectionCount} sections · ${entry.ruleCount} rules`,
            itemClass:
                entry.name === this.selectedName
                    ? 'set-item set-item_selected'
                    : 'set-item'
        }));
    }

    /** The model decorated for the template: options resolved per section,
     *  because a template cannot call a method with arguments. */
    get sectionRows() {
        return this.model.map((section) => {
            const writable = this.fieldOptions(section.targetObject, true);
            const queryable = this.fieldOptions(section.targetObject, false);
            const known = Boolean(
                section.targetObject && this.fieldCache[section.targetObject]
            );
            const ruleCount = section.rules.length;
            return {
                ...section,
                isRepeating: section.sectionType === 'Repeating',
                headline: section.label || section.name || '(unnamed section)',
                summary: `${section.targetObject || 'no object yet'} · ${ruleCount} rule${
                    ruleCount === 1 ? '' : 's'
                }`,
                fieldsUnknown: !known,
                matchFieldOptions: queryable,
                hasRules: ruleCount > 0,
                rules: section.rules.map((rule) => ({
                    ...rule,
                    targetFieldOptions: writable,
                    headline: rule.label || rule.name || '(unnamed rule)'
                }))
            };
        });
    }

    get findingRows() {
        return this.findings.map((finding, index) => ({
            key: `${index}-${finding.severity}`,
            message: finding.message,
            iconName:
                finding.severity === 'Error'
                    ? 'utility:error'
                    : 'utility:warning',
            rowClass:
                finding.severity === 'Error'
                    ? 'finding finding_error'
                    : 'finding finding_warning'
        }));
    }

    get dirty() {
        return !this.sameJson(this.currentJson(), this.savedJson || '{}');
    }

    get hasFindings() {
        return this.findings.length > 0;
    }

    get hasErrors() {
        return this.findings.some((finding) => finding.severity === 'Error');
    }

    get saveDisabled() {
        return (
            this.saving || !this.dirty || !this.selectedName || this.hasErrors
        );
    }

    get revertDisabled() {
        return this.saving || !this.dirty;
    }

    get noSelection() {
        return !this.selectedName;
    }

    get noSections() {
        return this.model.length === 0;
    }

    get statusLabel() {
        if (this.saving) {
            return 'Deploying…';
        }
        return this.dirty ? 'Unsaved changes' : 'Saved';
    }

    get statusClass() {
        if (this.saving) {
            return 'status status_deploying';
        }
        return this.dirty ? 'status status_dirty' : 'status status_clean';
    }

    // ───────────────────────────── helpers ──────────────────────────

    messageOf(e) {
        return (
            e?.body?.message ||
            e?.body?.pageErrors?.[0]?.message ||
            e?.message ||
            'Something went wrong.'
        );
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
