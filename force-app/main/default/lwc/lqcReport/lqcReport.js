import { LightningElement, api } from 'lwc';
import LOCALE from '@salesforce/i18n/locale';
import { fieldKey, parseColumnType } from 'c/lqcUtils';

/**
 * Calculated "Estimated Estate Value" report tab.
 *
 * Purely derived: for every data tab whose config marks a number column with
 * subtotal:true, renders a grey section row (tab title | "Value") followed by
 * white rows summarizing that tab — grouped by the groupBy:true column when
 * one exists, otherwise a single "Total" row — and closes with the bold,
 * double-height grand total row. Never persisted; recomputes whenever the
 * parent passes a new rowsMap or the refresh icon is clicked.
 */
export default class LqcReport extends LightningElement {
    /** Report header title from the JSON config (reportTitle, falls back to title). */
    @api title;
    /** Full tabs[] array from the JSON config. */
    @api tabs;
    /** Optional ISO currency code (e.g. "ZAR") to format amounts like R10 563 000. */
    @api currencyCode;

    _rowsMap = {};

    /** Live map of tabName -> rows, owned by the container. */
    @api
    get rowsMap() {
        return this._rowsMap;
    }
    set rowsMap(value) {
        this._rowsMap = value || {};
    }

    get formatter() {
        const options = this.currencyCode
            ? {
                  style: 'currency',
                  currency: this.currencyCode,
                  minimumFractionDigits: 0,
                  maximumFractionDigits: 2
              }
            : { minimumFractionDigits: 0, maximumFractionDigits: 2 };
        return new Intl.NumberFormat(LOCALE, options);
    }

    get sections() {
        const formatter = this.formatter;
        return (this.tabs || [])
            .map((tab) => this.buildSection(tab, formatter))
            .filter((section) => section !== null);
    }

    buildSection(tab, formatter) {
        const columns = tab.columns || [];
        const subtotalCol = columns.find(
            (col) => col.subtotal && parseColumnType(col.type).base === 'number'
        );
        if (!subtotalCol) {
            return null;
        }
        const subtotalKey = fieldKey(subtotalCol.name);
        const groupCol = columns.find((col) => col.groupBy);
        const rows = this._rowsMap[tab.name] || [];
        const total = rows.reduce((sum, row) => sum + this.numeric(row[subtotalKey]), 0);

        let lines;
        if (groupCol) {
            const groupKey = fieldKey(groupCol.name);
            const groups = new Map();
            rows.forEach((row) => {
                const label = row[groupKey] || 'Not specified';
                groups.set(label, (groups.get(label) || 0) + this.numeric(row[subtotalKey]));
            });
            lines = [...groups.entries()].map(([label, amount]) => ({
                key: `${tab.name}-${label}`,
                label,
                amount: formatter.format(amount)
            }));
        }
        if (!lines || lines.length === 0) {
            lines = [
                { key: `${tab.name}-total`, label: 'Total', amount: formatter.format(total) }
            ];
        }
        return { key: tab.name, title: tab.title, lines, total };
    }

    get grandTotal() {
        const total = (this.tabs || [])
            .map((tab) => this.buildSection(tab, this.formatter))
            .filter((section) => section !== null)
            .reduce((sum, section) => sum + section.total, 0);
        return this.formatter.format(total);
    }

    numeric(value) {
        const parsed = parseFloat(value);
        return Number.isNaN(parsed) ? 0 : parsed;
    }

    handleRefresh() {
        // Recompute from the latest rows: reassigning the map re-renders every
        // derived getter, and the event lets the container push a fresh copy.
        this._rowsMap = { ...this._rowsMap };
        this.dispatchEvent(new CustomEvent('refresh'));
    }
}
