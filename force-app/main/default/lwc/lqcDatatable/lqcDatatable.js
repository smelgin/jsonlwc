import LightningDatatable from 'lightning/datatable';
import picklistCell from './picklistCell.html';
import picklistCellEdit from './picklistCellEdit.html';

/**
 * lightning-datatable subclass adding a "picklist" cell type: displays the
 * value as text and edits through a lightning-combobox fed by the options
 * typeAttribute (built from the column's pipe-separated "values" config).
 */
export default class LqcDatatable extends LightningDatatable {
    static customTypes = {
        picklist: {
            template: picklistCell,
            editTemplate: picklistCellEdit,
            standardCellLayout: true,
            typeAttributes: ['options']
        }
    };
}
