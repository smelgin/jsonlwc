import { LightningElement, api, track } from 'lwc';
import getConfig from '@salesforce/apex/LqcController.getConfig';
import getSavedResult from '@salesforce/apex/LqcController.getSavedResult';
import saveResult from '@salesforce/apex/LqcController.saveResult';
import { reduceError } from 'c/lqcUtils';

const PAYLOAD_VERSION = 1;

/**
 * Liquidity Calculator (LQC) container.
 *
 * Loads the tab configuration from Custom_Configuration__mdt and any previously
 * saved state through the configured ILqcStorage strategy, renders one grid per data tab and
 * c-lqc-report for the calculated report tab, and provides Save / Publish.
 * Publish stores published:true in the payload, which locks every grid
 * read-only on subsequent loads.
 */
export default class LiquidityCalculator extends LightningElement {
    @api recordId;
    /** Optional: DeveloperName of the Custom_Configuration__mdt record to use. */
    @api configName;

    @track tabs = [];
    configTabs = [];
    published = false;
    isLoading = true;
    isSaving = false;
    banner; // component-level banner: { variant, message }

    tabRowsMap = {};

    connectedCallback() {
        this.load();
    }

    async load() {
        this.isLoading = true;
        try {
            const [configJson, savedJson] = await Promise.all([
                getConfig({ configName: this.configName || null }),
                getSavedResult({
                    recordId: this.recordId,
                    configName: this.configName || null
                })
            ]);
            const config = JSON.parse(configJson);
            const saved = savedJson ? JSON.parse(savedJson) : null;

            this.published = saved?.published === true;
            this.tabRowsMap = saved?.tabs ? { ...saved.tabs } : {};
            this.configTabs = config.tabs || [];
            this.tabs = this.configTabs.map((tab) => ({
                key: tab.name,
                config: tab,
                isReport: tab.type === 'report',
                reportTitle: tab.reportTitle || tab.title,
                initialRows: this.tabRowsMap[tab.name] || []
            }));
        } catch (error) {
            this.showBanner('error', `Unable to load the Liquidity Calculator: ${reduceError(error)}`);
        } finally {
            this.isLoading = false;
        }
    }

    /* ---------------------------------------------------------- getters */

    get hasTabs() {
        return this.tabs.length > 0;
    }

    get actionsDisabled() {
        return this.isLoading || this.isSaving || this.published;
    }

    /* ---------------------------------------------------------- banner */

    showBanner(variant, message) {
        this.banner = { variant, message };
    }

    handleBannerClose() {
        this.banner = undefined;
    }

    /* ---------------------------------------------------------- events */

    handleRowsChange(event) {
        const { name, rows } = event.detail;
        this.tabRowsMap = { ...this.tabRowsMap, [name]: rows };
    }

    handleReportRefresh() {
        // Push a fresh copy of the rows map so the report recalculates.
        this.tabRowsMap = { ...this.tabRowsMap };
    }

    /* ------------------------------------------------- save / publish */

    buildPayload(published) {
        return JSON.stringify({
            version: PAYLOAD_VERSION,
            published,
            savedAt: new Date().toISOString(),
            tabs: this.tabRowsMap
        });
    }

    async persist(published, successMessage) {
        this.isSaving = true;
        this.banner = undefined;
        try {
            await saveResult({
                recordId: this.recordId,
                payload: this.buildPayload(published),
                configName: this.configName || null
            });
            this.published = published;
            this.showBanner('success', successMessage);
        } catch (error) {
            this.showBanner('error', reduceError(error));
        } finally {
            this.isSaving = false;
        }
    }

    handleSave() {
        this.persist(this.published, 'Liquidity Calculator saved successfully.');
    }

    handlePublish() {
        this.persist(
            true,
            'Liquidity Calculator published. The grids are now locked.'
        );
    }
}
